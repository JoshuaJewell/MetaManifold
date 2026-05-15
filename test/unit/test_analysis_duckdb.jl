@testset "Analysis DuckDB helpers" begin

    # Set up an in-memory DuckDB with test data
    function _make_test_db()
        db = DuckDB.DB()
        con = DBInterface.connect(db)
        DBInterface.execute(con, """
            CREATE TABLE merged (
                SeqName VARCHAR,
                Domain VARCHAR,
                Phylum VARCHAR,
                Pident DOUBLE,
                s1 BIGINT,
                s2 BIGINT,
                s3 BIGINT,
                Domain_dada2 VARCHAR,
                Pident_boot DOUBLE
            )
        """)
        DBInterface.execute(con, """
            INSERT INTO merged VALUES
                ('seq1', 'Eukaryota', 'Chlorophyta',   95.0, 100, 50, 0, 'Eukaryota', 80.0),
                ('seq2', 'Eukaryota', 'Ochrophyta',    88.0, 30,  80, 10, 'Eukaryota', 75.0),
                ('seq3', 'Bacteria',  'Proteobacteria', 92.0, 0,   20, 40, 'Bacteria', 90.0)
        """)
        db, con
    end

    @testset "sample_columns" begin
        db, con = _make_test_db()
        try
            scols = Analysis.sample_columns(con, "merged")
            @test Set(scols) == Set(["s1", "s2", "s3"])
            @test "SeqName" ∉ scols
            @test "Domain" ∉ scols
            @test "Pident" ∉ scols
            @test "Domain_dada2" ∉ scols
            @test "Pident_boot" ∉ scols
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "taxonomy_levels" begin
        db, con = _make_test_db()
        try
            levels = Analysis.taxonomy_levels(con, "merged")
            @test "Domain" in levels
            @test "Phylum" in levels
            @test "SeqName" ∉ levels
            @test "s1" ∉ levels
            @test findfirst(==("Domain"), levels) < findfirst(==("Phylum"), levels)
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "taxonomy_levels - DADA2 suffixed columns" begin
        db = DuckDB.DB()
        con = DBInterface.connect(db)
        try
            DBInterface.execute(con, """
                CREATE TABLE dada2_ann (
                    SeqName VARCHAR,
                    Genus_dada2 VARCHAR,
                    Family_dada2 VARCHAR,
                    s1 BIGINT
                )
            """)
            levels = Analysis.taxonomy_levels(con, "dada2_ann")
            # Returns canonical names (no _dada2 suffix)
            @test "Genus"  in levels
            @test "Family" in levels
            @test "Genus_dada2"  ∉ levels
            @test "Family_dada2" ∉ levels
            @test "SeqName" ∉ levels
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "taxon_column" begin
        vsearch_cols = ["SeqName", "Genus", "Family", "s1"]
        dada2_cols   = ["SeqName", "Genus_dada2", "Family_dada2", "s1"]

        @test Analysis.taxon_column(vsearch_cols, "Genus")  == "Genus"
        @test Analysis.taxon_column(vsearch_cols, "Family") == "Family"
        @test Analysis.taxon_column(dada2_cols,   "Genus")  == "Genus_dada2"
        @test Analysis.taxon_column(dada2_cols,   "Family") == "Family_dada2"
        # Falls back to plain name when neither exists
        @test Analysis.taxon_column(vsearch_cols, "Order")  == "Order"
    end

    @testset "sequence_column_name" begin
        @test Analysis.sequence_column_name(["SeqName", "sequence", "s1"]) == "sequence"
        @test Analysis.sequence_column_name(["SeqName", "Sequence", "s1"]) == "Sequence"
        @test isnothing(Analysis.sequence_column_name(["SeqName", "ASV", "s1"]))
    end

    @testset "filtered_counts" begin
        db, con = _make_test_db()
        try
            scols = ["s1", "s2", "s3"]
            mat = Analysis.filtered_counts(con, "merged", scols, "", [])
            # Matrix: rows=samples, cols=features (ASVs)
            @test size(mat) == (3, 3)  # 3 samples x 3 ASVs
            # s1 column: [100, 30, 0]
            @test mat[1, :] == [100.0, 30.0, 0.0]
            # s2 column: [50, 80, 20]
            @test mat[2, :] == [50.0, 80.0, 20.0]
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "filtered_counts with WHERE clause" begin
        db, con = _make_test_db()
        try
            scols = ["s1", "s2"]
            mat = Analysis.filtered_counts(con, "merged", scols,
                "WHERE Domain = ?", ["Eukaryota"])
            @test size(mat) == (2, 2)  # 2 samples x 2 matching ASVs
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "filtered_counts empty result" begin
        db, con = _make_test_db()
        try
            scols = ["s1", "s2"]
            mat = Analysis.filtered_counts(con, "merged", scols,
                "WHERE Domain = ?", ["Nonexistent"])
            @test size(mat) == (2, 0)
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "filtered_df" begin
        db, con = _make_test_db()
        try
            df = Analysis.filtered_df(con, "merged", "WHERE Domain = ?", ["Bacteria"])
            @test nrow(df) == 1
            @test df.SeqName[1] == "seq3"
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "aggregate_by_taxon" begin
        db, con = _make_test_db()
        try
            scols = ["s1", "s2", "s3"]
            agg = Analysis.aggregate_by_taxon(con, "merged", scols,
                "Domain", "", [])
            @test nrow(agg) == 2  # Eukaryota, Bacteria
            @test "taxon" in names(agg)
            # Eukaryota should come first (higher total counts)
            @test agg.taxon[1] == "Eukaryota"
            # Eukaryota s1: 100 + 30 = 130
            euk_row = first(eachrow(filter(:taxon => ==("Eukaryota"), agg)))
            @test euk_row.s1 == 130
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "aggregate_by_taxon with filter" begin
        db, con = _make_test_db()
        try
            scols = ["s1", "s2"]
            agg = Analysis.aggregate_by_taxon(con, "merged", scols,
                "Phylum", "WHERE Domain = ?", ["Eukaryota"])
            @test nrow(agg) == 2  # Chlorophyta, Ochrophyta
            @test all(t -> t in ["Chlorophyta", "Ochrophyta"], agg.taxon)
        finally
            DBInterface.close!(con)
            close(db)
        end
    end

    @testset "combined_counts_across_runs" begin
        df1 = DataFrame(taxon=["Eukaryota", "Bacteria"], s1=[100, 50], s2=[80, 20])
        df2 = DataFrame(taxon=["Eukaryota", "Archaea"],  s3=[200, 30])

        run_data = [
            ("run_A", ["s1", "s2"], df1),
            ("run_B", ["s3"], df2),
        ]

        mat, all_samples, taxa_labels, run_labels = Analysis.combined_counts_across_runs(run_data)

        @test all_samples == ["s1", "s2", "s3"]
        @test run_labels == ["run_A", "run_A", "run_B"]
        @test length(taxa_labels) == 3  # Archaea, Bacteria, Eukaryota (sorted)
        @test size(mat) == (3, 3)  # 3 samples x 3 taxa

        # Eukaryota column should have values for all 3 samples
        euk_idx = findfirst(==("Eukaryota"), taxa_labels)
        @test mat[1, euk_idx] == 100.0  # s1
        @test mat[2, euk_idx] == 80.0   # s2
        @test mat[3, euk_idx] == 200.0  # s3

        # Bacteria only in run_A
        bac_idx = findfirst(==("Bacteria"), taxa_labels)
        @test mat[1, bac_idx] == 50.0
        @test mat[3, bac_idx] == 0.0  # not in run_B
    end

    @testset "venn_taxa_present" begin
        # Reuse _make_test_db() already defined at top of this testset.
        # Schema: SeqName, Domain, Phylum, s1, s2, s3, Domain_dada2, Pident_boot
        # Data:
        #   seq1 -> Domain=Eukaryota, Phylum=Chlorophyta,    s1=100, s2=50, s3=0
        #   seq2 -> Domain=Eukaryota, Phylum=Ochrophyta,     s1=30,  s2=80, s3=10
        #   seq3 -> Domain=Bacteria,  Phylum=Proteobacteria, s1=0,   s2=20, s3=40
        @testset "returns present taxa at Domain level" begin
            db, con = _make_test_db()
            try
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1", "s2", "s3"],
                                                  "Domain", "", [])
                @test Set(taxa) == Set(["Eukaryota", "Bacteria"])
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "returns present taxa at Phylum level" begin
            db, con = _make_test_db()
            try
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1", "s2", "s3"],
                                                  "Phylum", "", [])
                @test Set(taxa) == Set(["Chlorophyta", "Ochrophyta", "Proteobacteria"])
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "excludes taxa with zero reads in the given sample columns" begin
            db, con = _make_test_db()
            try
                # s3 only: seq1 has 0 in s3, seq3 has 40 in s3
                taxa = Analysis.venn_taxa_present(con, "merged", ["s3"],
                                                  "Domain", "", [])
                @test "Bacteria" in taxa
                # Eukaryota: seq1.s3=0, seq2.s3=10 -> total=10 -> still present
                @test "Eukaryota" in taxa
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "zero reads for all taxa in column -> returns only those with reads" begin
            db, con = _make_test_db()
            try
                # Only s1 for Bacteria row (seq3.s1 = 0) -> Bacteria absent, Eukaryota present
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1"],
                                                  "Domain", "WHERE s3 = 0", [])
                # seq1 (Eukaryota, s1=100) qualifies, seq3 (Bacteria, s1=0) does not
                @test "Eukaryota" in taxa
                @test "Bacteria" ∉ taxa
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "respects WHERE clause filter" begin
            db, con = _make_test_db()
            try
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1", "s2", "s3"],
                                                  "Phylum", "WHERE Domain = ?", ["Eukaryota"])
                @test Set(taxa) == Set(["Chlorophyta", "Ochrophyta"])
                @test "Proteobacteria" ∉ taxa
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "empty sample_cols returns empty vector" begin
            db, con = _make_test_db()
            try
                taxa = Analysis.venn_taxa_present(con, "merged", String[],
                                                  "Domain", "", [])
                @test isempty(taxa)
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "result is sorted" begin
            db, con = _make_test_db()
            try
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1", "s2", "s3"],
                                                  "Domain", "", [])
                @test taxa == sort(taxa)
            finally
                DBInterface.close!(con); close(db)
            end
        end

        @testset "null and blank taxa are coalesced to Unclassified" begin
            db = DuckDB.DB()
            con = DBInterface.connect(db)
            try
                DBInterface.execute(con, """
                    CREATE TABLE merged (
                        SeqName VARCHAR,
                        Domain VARCHAR,
                        s1 BIGINT
                    )
                """)
                DBInterface.execute(con, """
                    INSERT INTO merged VALUES
                        ('seq1', 'Eukaryota', 100),
                        ('seq2', NULL,         50),
                        ('seq3', '',           30),
                        ('seq4', '   ',        20)
                """)
                taxa = Analysis.venn_taxa_present(con, "merged", ["s1"],
                                                  "Domain", "", [])
                @test "Unclassified" in taxa
                @test "Eukaryota" in taxa
                @test length(taxa) == 2  # Eukaryota + Unclassified (NULL, '', '   ' all coalesced)
            finally
                DBInterface.close!(con); close(db)
            end
        end
    end

end
