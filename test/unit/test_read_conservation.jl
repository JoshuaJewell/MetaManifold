# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Read-count conservation
# Every figure this application reports as a read count must reconcile with the
# reads the pipeline actually produced. The defects guarded against here inflate
# totals by a clean multiple rather than by noise, which is why they survive
# inspection: a doubled total still reads as a plausible total.
#
# Two invariants underpin the lot:
#
#   Uniqueness. Every join key that names a sequence must be unique on both
#   sides, or the join fans rows out and multiplies their counts.
#
#   Partition. Every scheme that buckets reads (sample columns, categories,
#   sub-group prefixes) must be disjoint and total, or reads are counted twice
#   or dropped.
#
# Each assertion here began life as a `@test_broken` against a demonstrated defect:
# cross-run combination reported 110 reads as 220, an unguarded bootstrap join
# turned 100 reads into 200, and the data-table path summed integer OTU identifiers
# as though they were reads. All are now fixed, and these guard the fixes.

if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
SV = Main.Server

## A merged table shaped as the annotation step leaves it: two genuine sample
# columns, the derived `total_<subgroup>` and `total` aggregates written by
# `Annotation._add_totals!`, a bootstrap column, and an integer OTU identifier.
# True reads are S1 (10 + 40) + S2 (20 + 30) = 100.
function _annotated_merged_table()
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    DBInterface.execute(con, """
        CREATE TABLE merged (
            SeqName VARCHAR, Domain VARCHAR, Pident DOUBLE, OTU INTEGER,
            S1 INTEGER, S2 INTEGER, "Domain_boot" INTEGER,
            "total_grp" INTEGER, "total" INTEGER)
    """)
    DBInterface.execute(con, "INSERT INTO merged VALUES (?,?,?,?,?,?,?,?,?)",
                        ["asv1", "Eukaryota", 99.0, 7, 10, 20, 80, 30, 30])
    DBInterface.execute(con, "INSERT INTO merged VALUES (?,?,?,?,?,?,?,?,?)",
                        ["asv2", "Eukaryota", 98.0, 9, 40, 30, 70, 70, 70])
    con
end

# The reads genuinely present in `_annotated_merged_table`.
const _TRUE_READS = 100

@testset "Read-count conservation" begin

    ## Regression for the double-counting bug fixed in fbcec76: `total` and
    # `total_<subgroup>` are derived aggregates over the sample columns, so
    # summing them alongside the samples counts every read three times.
    @testset "derived total columns are never counted as samples" begin
        con = _annotated_merged_table()
        for cols in (Analysis.sample_columns(con, "merged"),
                     SV._sample_count_columns(con, "merged"))
            @test !("total" in cols)
            @test !("total_grp" in cols)
            @test !("Domain_boot" in cols)
        end
    end

    ## Two independent definitions of "sample column" exist: the chart path uses
    # `Analysis.sample_columns`, the data-table path uses
    # `_sample_count_columns`. They must agree, or two endpoints report different
    # read totals for the same run.
    @testset "every read-count path agrees on what a sample column is" begin
        con = _annotated_merged_table()
        analysis_cols = Analysis.sample_columns(con, "merged")
        table_cols    = SV._sample_count_columns(con, "merged")

        @test Set(analysis_cols) == Set(["S1", "S2"])
        # `_sample_count_columns` now delegates to `Analysis.sample_columns`, so the
        # integer OTU identifier is no longer summed as though it were reads.
        @test Set(table_cols) == Set(analysis_cols)
    end

    @testset "reported reads equal the sum of the sample columns" begin
        con = _annotated_merged_table()
        @test SV._sum_reads(con, "merged",
                            Analysis.sample_columns(con, "merged")) == _TRUE_READS
        @test SV._sum_reads(con, "merged",
                            SV._sample_count_columns(con, "merged")) == _TRUE_READS
    end

    ## The merged table is taxonomically filtered after chimera removal, so its
    # read total is bounded above by, not equal to, the pipeline's `nochim`
    # total. Filtering only ever lowers it; an inflation bug breaches the bound.
    # This is the cheapest end-to-end detector of the whole defect class.
    @testset "reported reads never exceed the pipeline nochim total" begin
        con = _annotated_merged_table()
        # `pipeline_stats.csv` as compute_pipeline_stats writes it: one row per
        # sample, `nochim` being that sample's reads after chimera removal.
        stats = DataFrame(sample = ["S1", "S2"],
                          input    = [200, 180],
                          filtered = [150, 140],
                          nochim   = [50, 50])
        nochim_total = sum(stats.nochim)
        @test nochim_total == _TRUE_READS

        @test SV._sum_reads(con, "merged",
                            Analysis.sample_columns(con, "merged")) <= nochim_total
        @test SV._sum_reads(con, "merged",
                            SV._sample_count_columns(con, "merged")) <= nochim_total
    end

    ## Cross-run combination keys its accumulator by sample-column NAME, and that
    # name is only unique within a run. Two runs sharing a column name (as pooled
    # runs do when a sub-group prefix recurs) have their reads summed together,
    # and the pooled figure is then written into both rows of the matrix.
    @testset "cross-run combination conserves reads" begin
        df_a = DataFrame(taxon = ["Fungi"], S1 = [10])
        df_b = DataFrame(taxon = ["Fungi"], S1 = [100])
        mat, samples, _, runs = Analysis.combined_counts_across_runs(
            [("runA", ["S1"], df_a), ("runB", ["S1"], df_b)])

        @test samples == ["S1", "S1"]
        @test runs    == ["runA", "runB"]
        # This matrix feeds NMDS, PERMANOVA and the cross-run comparison charts,
        # so each row must carry only its own run's reads.
        @test sum(mat) == 110
        @test mat == reshape([10.0, 100.0], 2, 1)
    end

    @testset "cross-run ASV combination conserves reads" begin
        df_a = DataFrame(sequence = ["ACGT"], S1 = [10])
        df_b = DataFrame(sequence = ["ACGT"], S1 = [100])
        mat, _, _, _ = Analysis.combined_asv_counts_across_runs(
            [("runA", ["S1"], df_a), ("runB", ["S1"], df_b)])
        @test sum(mat) == 110
        @test mat == reshape([10.0, 100.0], 2, 1)
    end

    ## `merge_taxonomy_counts` guards SeqName uniqueness on the taxonomy and the
    # counts inputs, naming this exact hazard, and then performs a third join, on
    # the bootstraps, which must be guarded alike: a duplicated SeqName there fans
    # the row out and counts its reads twice everywhere downstream.
    @testset "the bootstrap join conserves reads" begin
        db = DatabaseMeta("silva", ["Domain", "Phylum"], "silva",
                          Dict{String,Any}[], Set{String}())

        vsearch_tmp = tempname() * ".tsv"
        write(vsearch_tmp, "seq1\tBacteria;Firmicutes\t95.0\n")
        counts_tmp = tempname() * ".csv"
        write(counts_tmp, "SeqName,sample1\nseq1,100\n")
        boot_tmp = tempname() * ".csv"
        write(boot_tmp, "SeqName,Domain_boot\nseq1,90\n")
        # seq1 is duplicated in the bootstraps file alone.
        dup_boot_tmp = tempname() * ".csv"
        write(dup_boot_tmp, "SeqName,Domain_boot\nseq1,90\nseq1,80\n")

        df = TaxonomyTableTools.merge_taxonomy_counts(
            vsearch_tmp, counts_tmp, db; bootstraps_path=boot_tmp)

        @test nrow(df) == 1
        @test sum(skipmissing(df[!, :sample1])) == 100

        # Scaling reads silently is the worse failure, so the merge refuses the
        # duplicate outright, as it does on the taxonomy and counts inputs.
        @test_throws ErrorException TaxonomyTableTools.merge_taxonomy_counts(
            vsearch_tmp, counts_tmp, db; bootstraps_path=dup_boot_tmp)

        rm(vsearch_tmp); rm(counts_tmp); rm(boot_tmp); rm(dup_boot_tmp)
    end

end
