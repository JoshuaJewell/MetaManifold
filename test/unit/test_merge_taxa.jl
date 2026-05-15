@testset "merge_taxa helpers" begin

    @testset "_first_duplicates" begin
        @test TaxonomyTableTools._first_duplicates(["a", "b", "c"]) == ""
        @test TaxonomyTableTools._first_duplicates(["a", "b", "a"]) == "\"a\""
        # A duplicate is reported only once even if it appears many times.
        @test TaxonomyTableTools._first_duplicates(["a", "a", "a"]) == "\"a\""
        # The limit caps the number reported.
        many = ["x$i" for i in 1:10]
        repeated = vcat(many, many)
        out = TaxonomyTableTools._first_duplicates(repeated; limit=3)
        @test count(==(','), out) == 2  # three entries => two commas
    end

    @testset "seqnum" begin
        @test TaxonomyTableTools.seqnum("seq1")   == 1
        @test TaxonomyTableTools.seqnum("seq10")  == 10
        @test TaxonomyTableTools.seqnum("seq100") == 100
        @test TaxonomyTableTools.seqnum("otu1")   == 1
        @test TaxonomyTableTools.seqnum("otu42")  == 42
        @test TaxonomyTableTools.seqnum("other")  == typemax(Int)
        @test TaxonomyTableTools.seqnum(missing)  == typemax(Int)
        ids = ["seq3", "seq1", "seq10", "seq2"]
        @test sort(ids, by=TaxonomyTableTools.seqnum) == ["seq1", "seq2", "seq3", "seq10"]
    end

    @testset "vsearch_to_df" begin
        rows = [
            ["seq1", "Bacteria;Firmicutes;Clostridia", "95.5"],
            ["seq2", "Bacteria;Proteobacteria;Gammaproteobacteria", "88.0"],
        ]
        df = TaxonomyTableTools.vsearch_to_df(rows)
        @test nrow(df) == 2
        @test "SeqName" in names(df)
        @test "Pident"  in names(df)
        @test "sseqtax" in names(df)
        @test df.SeqName == ["seq1", "seq2"]
        @test df.Pident  ≈ [95.5, 88.0]

        df2 = TaxonomyTableTools.vsearch_to_df([["seq1", "tax"]])
        @test nrow(df2) == 0
    end

    @testset "import_vsearch" begin
        tmp = tempname() * ".tsv"
        write(tmp, "seq1\tBacteria;Firmicutes\t95.0\nseq2\tBacteria;Proteobacteria\t88.0\n")
        rows = TaxonomyTableTools.import_vsearch(tmp)
        rm(tmp)
        @test length(rows) == 2
        @test rows[1] == ["seq1", "Bacteria;Firmicutes", "95.0"]
        @test rows[2] == ["seq2", "Bacteria;Proteobacteria", "88.0"]
    end

    @testset "filter_table - exclude" begin
        df = DataFrame(
            SeqName = ["seq1", "seq2", "seq3"],
            Domain  = ["Bacteria", "Eukaryota", "Bacteria"],
            sample1 = [10, 20, 30],
        )
        tmp = tempname() * ".yml"
        write(tmp, """
filters:
  - column: Domain
    pattern: "Bacteria"
    action: exclude
""")
        result = filter_table(df, tmp)
        rm(tmp)
        @test nrow(result) == 1
        @test result.SeqName == ["seq2"]
    end

    @testset "filter_table - keep" begin
        df = DataFrame(
            SeqName = ["seq1", "seq2", "seq3"],
            Domain  = ["Bacteria", "Eukaryota", "Bacteria"],
            sample1 = [10, 20, 30],
        )
        tmp = tempname() * ".yml"
        write(tmp, """
filters:
  - column: Domain
    pattern: "Bacteria"
    action: keep
""")
        result = filter_table(df, tmp)
        rm(tmp)
        @test nrow(result) == 2
        @test all(result.Domain .== "Bacteria")
    end

    @testset "filter_table - remove_empty" begin
        df = DataFrame(
            SeqName = ["seq1", "seq2", "seq3"],
            Domain  = ["Bacteria", "", missing],
            sample1 = [10, 20, 30],
        )
        tmp = tempname() * ".yml"
        write(tmp, "remove_empty:\n  - Domain\n")
        result = filter_table(df, tmp)
        rm(tmp)
        @test nrow(result) == 1
        @test result.SeqName == ["seq1"]
    end

    @testset "build_taxonomy_table_rows - generic" begin
        df = DataFrame(
            SeqName  = ["seq1", "seq2"],
            Pident   = [95.0, 88.0],
            sseqtax  = ["Bacteria;Firmicutes;Clostridia", "Bacteria;Proteobacteria"],
        )
        db = DatabaseMeta("silva", ["Domain","Phylum","Class"], "silva",
                          Dict{String,Any}[], Set{String}())
        header, rows = TaxonomyTableTools.build_taxonomy_table_rows(df, db)
        @test header == ["SeqName","Pident","Domain","Phylum","Class"]
        @test rows[1][3] == "Bacteria"
        @test rows[1][4] == "Firmicutes"
        @test rows[1][5] == "Clostridia"
        @test rows[2][4] == "Proteobacteria"
        @test rows[2][5] == ""   # rank not present -> empty
    end

    @testset "build_taxonomy_table_rows - PR2 pipe format" begin
        df = DataFrame(
            SeqName  = ["seq1"],
            Pident   = [97.0],
            sseqtax  = ["AB123|18S|nucleus|uncultured|Eukaryota|Opisthokonta|Fungi|Ascomycota|Saccharomycetes|Saccharomycetales|Saccharomycetaceae|Saccharomyces|Saccharomyces_cerevisiae"],
        )
        levels = ["Domain","Supergroup","Division","Class","Order","Family","Genus","Species"]
        db = DatabaseMeta("pr2", levels, "pr2", Dict{String,Any}[], Set{String}())
        header, rows = TaxonomyTableTools.build_taxonomy_table_rows(df, db)
        # PR2 pipe: first 4 fields are Accession, rRNA, Organellum, specimen; then taxonomy
        @test rows[1][3] == "AB123"   # Accession
        @test rows[1][7] == "Eukaryota"  # Domain (index 3 + 4 meta = 7)
    end

    @testset "build_taxonomy_table_rows - PR2 taxonomy-only" begin
        df = DataFrame(
            SeqName  = ["seq1"],
            Pident   = [97.0],
            sseqtax  = ["Eukaryota;Opisthokonta;Fungi;Ascomycota"],
        )
        levels = ["Domain","Supergroup","Division","Class","Order","Family","Genus","Species"]
        db = DatabaseMeta("pr2", levels, "pr2", Dict{String,Any}[], Set{String}())
        header, rows = TaxonomyTableTools.build_taxonomy_table_rows(df, db)
        # No pipe -> taxonomy-only branch: Domain starts at tax_start
        tax_start = length(header) - length(levels) + 1
        @test rows[1][tax_start]     == "Eukaryota"
        @test rows[1][tax_start + 1] == "Opisthokonta"
        @test rows[1][tax_start + 2] == "Fungi"
        @test rows[1][tax_start + 3] == "Ascomycota"
        @test rows[1][tax_start + 4] == ""   # missing rank
    end

    @testset "_with_dada2_as_primary / _restore round-trip" begin
        df = DataFrame(
            SeqName      = ["seq1"],
            Domain       = ["Eukaryota"],
            Domain_dada2 = ["Bacteria"],
            Pident       = [95.0],
            Pident_dada2 = [88.0],
        )
        swapped = TaxonomyTableTools._with_dada2_as_primary(df, ["Domain"])
        @test swapped.Domain[1]         == "Bacteria"
        @test "Domain_vsearch" in names(swapped)
        @test swapped.Domain_vsearch[1] == "Eukaryota"
        @test swapped.Pident[1]         == 88.0

        restored = TaxonomyTableTools._restore_from_dada2_primary(swapped, ["Domain"])
        @test restored.Domain[1]       == "Eukaryota"
        @test restored.Domain_dada2[1] == "Bacteria"
        @test !("Domain_vsearch" in names(restored))
        @test restored.Pident[1]       == 95.0
    end

    @testset "filter_table - missing column warns and skips" begin
        df = DataFrame(SeqName=["seq1"], Domain=["Eukaryota"], sample1=[10])
        tmp = tempname() * ".yml"
        write(tmp, """
filters:
  - column: Nonexistent
    pattern: "something"
    action: exclude
""")
        result = @test_logs (:warn, r"column 'Nonexistent' not present") min_level=Logging.Warn filter_table(df, tmp)
        rm(tmp)
        @test nrow(result) == 1
    end

    @testset "filter_table_dada2" begin
        df = DataFrame(
            SeqName      = ["seq1", "seq2"],
            Domain       = ["Eukaryota", "Bacteria"],
            Domain_dada2 = ["Bacteria",  "Bacteria"],
            sample1      = [10, 20],
        )
        tmp = tempname() * ".yml"
        write(tmp, """
filters:
  - column: Domain
    pattern: "Bacteria"
    action: keep
""")
        result = TaxonomyTableTools.filter_table_dada2(df, tmp, ["Domain"])
        rm(tmp)
        # Filter applied to _dada2 columns: both rows have Domain_dada2 = Bacteria -> both kept
        @test nrow(result) == 2
        # Original column names are restored
        @test "Domain" in names(result) && "Domain_dada2" in names(result)
    end

    @testset "merge_taxonomy_counts - generic format" begin
        db = DatabaseMeta("silva", ["Domain","Phylum"], "silva",
                          Dict{String,Any}[], Set{String}())

        vsearch_tmp = tempname() * ".tsv"
        write(vsearch_tmp,
            "seq1\tBacteria;Firmicutes\t95.0\n" *
            "seq2\tBacteria;Proteobacteria\t88.0\n")

        counts_tmp = tempname() * ".csv"
        write(counts_tmp, "SeqName,sample1,sample2\nseq1,100,50\nseq2,30,20\n")

        df = TaxonomyTableTools.merge_taxonomy_counts(vsearch_tmp, counts_tmp, db)
        rm(vsearch_tmp); rm(counts_tmp)

        @test nrow(df) == 2
        @test "Domain" in names(df)
        @test "Phylum" in names(df)
        @test "sample1" in names(df)
        @test df[df.SeqName .== "seq1", :Domain][1] == "Bacteria"
        @test df[df.SeqName .== "seq1", :Phylum][1] == "Firmicutes"
        @test sum(skipmissing(df[!, :sample1])) == 130
    end

    @testset "merge_taxonomy_counts - rejects duplicate SeqName in taxonomy" begin
        db = DatabaseMeta("silva", ["Domain","Phylum"], "silva",
                          Dict{String,Any}[], Set{String}())

        vsearch_tmp = tempname() * ".tsv"
        # seq1 appears twice in the vsearch input. The outer join would
        # otherwise silently inflate seq1's per-sample counts.
        write(vsearch_tmp,
            "seq1\tBacteria;Firmicutes\t95.0\n" *
            "seq1\tBacteria;Bacteroidetes\t90.0\n" *
            "seq2\tBacteria;Proteobacteria\t88.0\n")

        counts_tmp = tempname() * ".csv"
        write(counts_tmp, "SeqName,sample1\nseq1,100\nseq2,30\n")

        @test_throws ErrorException TaxonomyTableTools.merge_taxonomy_counts(
            vsearch_tmp, counts_tmp, db)
        rm(vsearch_tmp); rm(counts_tmp)
    end

    @testset "merge_taxonomy_counts - rejects duplicate SeqName in counts" begin
        db = DatabaseMeta("silva", ["Domain","Phylum"], "silva",
                          Dict{String,Any}[], Set{String}())

        vsearch_tmp = tempname() * ".tsv"
        write(vsearch_tmp,
            "seq1\tBacteria;Firmicutes\t95.0\n" *
            "seq2\tBacteria;Proteobacteria\t88.0\n")

        counts_tmp = tempname() * ".csv"
        write(counts_tmp, "SeqName,sample1\nseq1,100\nseq1,50\nseq2,30\n")

        @test_throws ErrorException TaxonomyTableTools.merge_taxonomy_counts(
            vsearch_tmp, counts_tmp, db)
        rm(vsearch_tmp); rm(counts_tmp)
    end

    @testset "merge_taxonomy_counts - parent_X fill" begin
        # Genus is empty -> should become Phylum_X
        db = DatabaseMeta("silva", ["Domain","Phylum","Genus"], "silva",
                          Dict{String,Any}[], Set{String}())

        vsearch_tmp = tempname() * ".tsv"
        write(vsearch_tmp, "seq1\tBacteria;Firmicutes;\t95.0\n")

        counts_tmp = tempname() * ".csv"
        write(counts_tmp, "SeqName,s1\nseq1,100\n")

        df = TaxonomyTableTools.merge_taxonomy_counts(vsearch_tmp, counts_tmp, db)
        rm(vsearch_tmp); rm(counts_tmp)

        @test df[1, :Genus] == "Firmicutes_X"
    end

    @testset "filter_table - regex" begin
        df = DataFrame(
            SeqName = ["seq1", "seq2", "seq3"],
            Species = ["Homo_sapiens", "Mus_musculus", "Canis_lupus"],
            sample1 = [1, 2, 3],
        )
        tmp = tempname() * ".yml"
        write(tmp, """
filters:
  - column: Species
    pattern: "^Homo"
    action: keep
    regex: true
""")
        result = filter_table(df, tmp)
        rm(tmp)
        @test nrow(result) == 1
        @test result.Species[1] == "Homo_sapiens"
    end

end
