# Unit tests for the composition route's table builder.
#
# Exercises `Server._build_composition!` end-to-end against a synthetic merged
# DuckDB, focusing on sub-group scoping: when subgroups are supplied, the
# composed table must drop sample columns outside the chosen sub-groups and
# rows whose summed reads across the kept columns are zero.

if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
SV = Main.Server

@testset "Composition build" begin

    ## Pure SQL fragment combiner: no DB or fixture needed.
    @testset "_combine_where_clauses" begin
        @test SV._combine_where_clauses() == ""
        @test SV._combine_where_clauses("", "") == ""
        @test SV._combine_where_clauses("WHERE a = 1", "") == "WHERE (a = 1)"
        @test SV._combine_where_clauses("", "WHERE b > 0") == "WHERE (b > 0)"
        ## Parentheses must preserve OR/AND precedence across fragments.
        @test SV._combine_where_clauses("WHERE a = 1 OR x = 2", "WHERE b > 0") ==
              "WHERE (a = 1 OR x = 2) AND (b > 0)"
        ## A fragment missing the leading "WHERE " is still accepted.
        @test SV._combine_where_clauses("a = 1", "b > 0") ==
              "WHERE (a = 1) AND (b > 0)"
    end

    @testset "sub-group scoping" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)

            study = "studyT"
            run   = "runT"
            merge_dir = joinpath(tmp, "projects", study, run, "merged")
            mkpath(merge_dir)

            ## Minimal category set: one filter that captures Eukaryota rows;
            ## every other row falls through to the implicit ELSE 'Unassigned'.
            cfg_comps = joinpath(tmp, "config", "compositions")
            cfg_filt  = joinpath(tmp, "config", "filters")
            mkpath(cfg_comps); mkpath(cfg_filt)
            write(joinpath(cfg_comps, "test_set.yml"), """
            name: Test categories
            description: Fixture for composition tests
            categories:
              - name: Eukaryota
                filter: euk.yml
            """)
            write(joinpath(cfg_filt, "euk.yml"), """
            filters:
              - column: Domain
                pattern: Eukaryota
                action: keep
            """)

            ## Synthetic merged DuckDB with two sub-group prefixes (A_, B_).
            ## Reads are arranged so that each sub-group scope drops at least
            ## one ASV outside it, exercising the row filter.
            db_path = joinpath(merge_dir, "results.duckdb")
            db  = DuckDB.DB(db_path)
            con = DBInterface.connect(db)
            try
                DBInterface.execute(con, """
                    CREATE TABLE merged (
                        "SeqName" VARCHAR,
                        "Domain"  VARCHAR,
                        "A_s1"    BIGINT,
                        "A_s2"    BIGINT,
                        "B_s1"    BIGINT
                    )
                """)
                DBInterface.execute(con, """
                    INSERT INTO merged VALUES
                        ('asv1','Eukaryota',10,0,0),
                        ('asv2','Eukaryota', 0,0,50),
                        ('asv3','Eukaryota', 5,0,5),
                        ('asv4','Bacteria',  7,3,0),
                        ('asv5','',          0,0,1)
                """)
            finally
                DBInterface.close!(con); close(db)
            end

            decode(resp) = JSON3.read(String(resp.body))

            ## No sub-groups: every sample column, every row.
            r0 = SV._build_composition!(study, run, "VSEARCH", "merged", "test_set")
            @test r0.status == 200
            d0 = decode(r0)
            @test d0["total_rows"]  == 5
            @test d0["total_reads"] == 81  # 10+50+10+10+1
            @test d0["categories"]["Eukaryota"]["rows"]  == 3
            @test d0["categories"]["Eukaryota"]["reads"] == 70  # 10+50+10
            @test d0["categories"]["Unassigned"]["rows"]  == 2
            @test d0["categories"]["Unassigned"]["reads"] == 11  # 10+1

            ## Sub-group A: drop B_s1 column; drop ASVs with A_s1+A_s2 == 0
            ## (asv2 and asv5 fall out). Reads count only A_s1 and A_s2.
            rA = SV._build_composition!(study, run, "VSEARCH", "merged", "test_set";
                                        subgroups=["A"])
            @test rA.status == 200
            dA = decode(rA)
            @test dA["total_rows"]  == 3
            @test dA["total_reads"] == 25  # 10 + 5 + 10
            @test dA["categories"]["Eukaryota"]["rows"]  == 2
            @test dA["categories"]["Eukaryota"]["reads"] == 15  # asv1 + asv3
            @test dA["categories"]["Unassigned"]["rows"]  == 1
            @test dA["categories"]["Unassigned"]["reads"] == 10  # asv4

            ## After the A-scoped build, the composed DuckDB must hold A_s1 and
            ## A_s2 but not B_s1. This confirms the column-drop side of the
            ## scoping, complementing the row-count assertions above.
            comp_path = joinpath(tmp, "projects", study, run,
                                 "composition", "VSEARCH", "composition.duckdb")
            @test isfile(comp_path)
            db2 = DuckDB.DB(comp_path; readonly=true)
            c2  = DBInterface.connect(db2)
            try
                cols = String[string(r.column_name) for r in eachrow(DataFrame(
                    DBInterface.execute(c2,
                        "SELECT column_name FROM information_schema.columns " *
                        "WHERE table_name = 'composition'")))]
                @test "A_s1" in cols
                @test "A_s2" in cols
                @test !("B_s1" in cols)
            finally
                DBInterface.close!(c2); close(db2)
            end

            ## Sub-group B: drop A columns; ASVs with B_s1 == 0 fall out.
            rB = SV._build_composition!(study, run, "VSEARCH", "merged", "test_set";
                                        subgroups=["B"])
            @test rB.status == 200
            dB = decode(rB)
            @test dB["total_rows"]  == 3
            @test dB["total_reads"] == 56  # 50 + 5 + 1
            @test dB["categories"]["Eukaryota"]["rows"]  == 2
            @test dB["categories"]["Eukaryota"]["reads"] == 55  # asv2 + asv3
            @test dB["categories"]["Unassigned"]["rows"]  == 1
            @test dB["categories"]["Unassigned"]["reads"] == 1   # asv5

            ## A and B together must reproduce the unrestricted totals exactly:
            ## the sample columns are disjoint, so the union covers everything.
            rAB = SV._build_composition!(study, run, "VSEARCH", "merged", "test_set";
                                         subgroups=["A", "B"])
            @test rAB.status == 200
            dAB = decode(rAB)
            @test dAB["total_rows"]  == 5
            @test dAB["total_reads"] == 81

            ## A sub-group whose prefix matches no sample column is a client error.
            rX = SV._build_composition!(study, run, "VSEARCH", "merged", "test_set";
                                        subgroups=["X"])
            @test rX.status == 400
            @test decode(rX)["error"] == "no_subgroup_samples"
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

end
