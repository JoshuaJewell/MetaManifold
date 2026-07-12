# Unit tests for the composition routes.
#
# The sub-group scoping and double-counting cases from the old build path are
# ported to the live summary path: a merged DuckDB is built in a temp dir with
# sample columns A_s1, A_s2, B_s1 and a Domain column; `_composition_summary`
# is then called directly with varying sub-group arguments and its output is
# asserted against the same row/read totals the old build asserted.

if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end
SV = Main.Server

@testset "Composition build" begin

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

            ## No sub-group: every sample column, every row with nonzero reads.
            r0 = SV._composition_summary(study, run, "test_set", nothing)
            @test r0.status == 200
            d0 = decode(r0)
            @test d0["total_rows"]  == 5
            @test d0["total_reads"] == 81  # 10+50+10+10+1
            @test d0["categories"]["Eukaryota"]["rows"]  == 3
            @test d0["categories"]["Eukaryota"]["reads"] == 70  # 10+50+10
            @test d0["categories"]["Unassigned"]["rows"]  == 2
            @test d0["categories"]["Unassigned"]["reads"] == 11  # 10+1

            ## Sub-group A: only A_s1 and A_s2 count; rows with zero A reads
            ## are excluded by the WHERE (row_sum) > 0 clause (asv2 and asv5 fall out).
            rA = SV._composition_summary(study, run, "test_set", "A")
            @test rA.status == 200
            dA = decode(rA)
            @test dA["total_rows"]  == 3
            @test dA["total_reads"] == 25  # 10 + 5 + 10
            @test dA["categories"]["Eukaryota"]["rows"]  == 2
            @test dA["categories"]["Eukaryota"]["reads"] == 15  # asv1 + asv3
            @test dA["categories"]["Unassigned"]["rows"]  == 1
            @test dA["categories"]["Unassigned"]["reads"] == 10  # asv4

            ## Sub-group B: only B_s1 counts; rows with B_s1 == 0 fall out.
            rB = SV._composition_summary(study, run, "test_set", "B")
            @test rB.status == 200
            dB = decode(rB)
            @test dB["total_rows"]  == 3
            @test dB["total_reads"] == 56  # 50 + 5 + 1
            @test dB["categories"]["Eukaryota"]["rows"]  == 2
            @test dB["categories"]["Eukaryota"]["reads"] == 55  # asv2 + asv3
            @test dB["categories"]["Unassigned"]["rows"]  == 1
            @test dB["categories"]["Unassigned"]["reads"] == 1   # asv5

            ## A sub-group whose prefix matches no sample column is a client error.
            rX = SV._composition_summary(study, run, "test_set", "X")
            @test rX.status == 400
            @test decode(rX)["error"] == "no_subgroup_samples"
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## Feature 1: category-set colour persistence (save/delete round-trips).
    @testset "category-set save and delete" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            cfg_comps = joinpath(tmp, "config", "compositions")
            mkpath(cfg_comps)

            ## A base set carrying both `filter` and `funcdb_require`, so we can
            ## confirm those survive a colour-only save byte-for-byte.
            write(joinpath(cfg_comps, "base.yml"), """
            name: Base categories
            description: Fixture base for save tests
            categories:
              - name: Protozoa
                colour: "#3498db"
                filter: protist.yml
              - name: Pathogens
                colour: "#800020"
                filter: bacteria.yml
                funcdb_require:
                  human_pathogen: "yes"
            """)

            ## Save under a new name with one colour override; the base is untouched.
            saved = SV._save_category_set("recoloured", "base",
                Dict("Protozoa" => "#abcdef"))
            @test saved isa AbstractDict   # a summary, not an error response
            @test saved["name"] == "recoloured"
            cat_by_name = Dict(c["name"] => c for c in saved["categories"])
            @test cat_by_name["Protozoa"]["colour"] == "#abcdef"   # overridden
            @test cat_by_name["Pathogens"]["colour"] == "#800020"  # preserved

            ## The base YAML on disk is unchanged by a save-as.
            base_reload = SV._load_category_set("base")
            base_proto = first(c for c in base_reload["categories"] if c["name"] == "Protozoa")
            @test base_proto["colour"] == "#3498db"

            ## The saved set preserves every category's `filter` and
            ## `funcdb_require` verbatim.
            reload = SV._load_category_set("recoloured")
            saved_by_name = Dict(c["name"] => c for c in reload["categories"])
            @test saved_by_name["Protozoa"]["filter"] == "protist.yml"
            @test saved_by_name["Pathogens"]["filter"] == "bacteria.yml"
            @test saved_by_name["Pathogens"]["funcdb_require"]["human_pathogen"] == "yes"
            ## Category order is stable (OrderedDict write).
            @test [c["name"] for c in reload["categories"]] == ["Protozoa", "Pathogens"]

            ## An invalid colour is rejected without touching disk.
            bad = SV._save_category_set("bad", "base", Dict("Protozoa" => "blue"))
            @test bad.status == 400
            @test JSON3.read(String(bad.body))["error"] == "invalid_colour"
            @test !isfile(joinpath(cfg_comps, "bad.yml"))

            ## A missing base set is a 404.
            nob = SV._save_category_set("x", "absent", Dict{String,String}())
            @test nob.status == 404
            @test JSON3.read(String(nob.body))["error"] == "base_not_found"

            ## Delete removes the file and returns the name.
            @test isfile(joinpath(cfg_comps, "recoloured.yml"))
            del = SV._delete_category_set("recoloured")
            @test del == "recoloured"
            @test !isfile(joinpath(cfg_comps, "recoloured.yml"))

            ## Deleting an absent set is a 404.
            del2 = SV._delete_category_set("recoloured")
            @test del2.status == 404
            @test JSON3.read(String(del2.body))["error"] == "set_not_found"

            ## `default` is protected even if a file exists.
            write(joinpath(cfg_comps, "default.yml"), "name: Default\ncategories: []\n")
            deld = SV._delete_category_set("default")
            @test deld.status == 400
            @test JSON3.read(String(deld.body))["error"] == "protected_set"
            @test isfile(joinpath(cfg_comps, "default.yml"))
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## Feature: Unassigned colour is persisted and resolved through the category set.
    @testset "unassigned colour" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            comp_dir = joinpath(tmp, "config", "compositions")
            mkpath(comp_dir)
            write(joinpath(comp_dir, "base.yml"), """
            name: Base
            description: test
            categories:
              - name: Fungi
                colour: "#f1c40f"
                filter: fungi.pr2.yml
            """)

            # Saving an "Unassigned" colour writes the top-level field, not a category.
            saved = SV._save_category_set("recol", "base",
                Dict("Unassigned" => "#112233", "Fungi" => "#abcdef"))
            @test saved["unassigned_colour"] == "#112233"
            on_disk = SV._load_category_set("recol")
            @test on_disk["unassigned_colour"] == "#112233"
            @test all(c -> get(c, "name", "") != "Unassigned", on_disk["categories"])
            @test SV._category_set_summary("recol", on_disk)["unassigned_colour"] == "#112233"
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

end
