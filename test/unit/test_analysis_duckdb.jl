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
            # Non-count columns excluded
            @test "SeqName" ∉ scols
            @test "Domain" ∉ scols
            @test "Pident" ∉ scols
            # Suffixed columns excluded
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
            # Non-taxonomy columns excluded
            @test "SeqName" ∉ levels
            @test "s1" ∉ levels
            # Domain comes before Phylum in the canonical order
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

end
