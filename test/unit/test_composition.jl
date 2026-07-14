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
            # The composition library is the single source of truth for both
            # the set's existence and its classification SQL.
            mkpath(joinpath(tmp, "config"))
            write(joinpath(tmp, "config", "composition.yml"), """
            filters:
              euk:
                filters:
                  - { column: Domain, pattern: Eukaryota, action: keep }
            sets:
              test_set:
                label: Test categories
                description: Fixture for composition tests
                categories:
                  - { name: Eukaryota, filter: euk }
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

            ## A category set absent from the library is a 404 (CRITICAL 2 guard):
            ## the existence gate and the classification SQL now share one source.
            rNone = SV._composition_summary(study, run, "absent_set", nothing)
            @test rNone.status == 404
            @test decode(rNone)["error"] == "category_set_not_found"
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## Feature 1: category-set colour persistence (save/delete round-trips).
    @testset "category-set save and delete" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            mkpath(joinpath(tmp, "config"))

            ## A base set carrying both `filter` and `funcdb_require`, so we can
            ## confirm those survive a colour-only save byte-for-byte.
            write(joinpath(tmp, "config", "composition.yml"), """
            filters:
              protist:
                filters:
                  - { column: Domain, pattern: Eukaryota, action: keep }
              bacteria:
                filters:
                  - { column: Domain, pattern: Bacteria, action: keep }
            sets:
              base:
                label: Base categories
                description: Fixture base for save tests
                categories:
                  - name: Protozoa
                    colour: "#3498db"
                    filter: protist
                  - name: Pathogens
                    colour: "#800020"
                    filter: bacteria
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

            ## The base set in the library is unchanged by a save-as.
            base_reload = SV._library()["sets"]["base"]
            base_proto = first(c for c in base_reload["categories"] if c["name"] == "Protozoa")
            @test base_proto["colour"] == "#3498db"

            ## The saved set preserves every category's `filter` and
            ## `funcdb_require` verbatim.
            reload = SV._library()["sets"]["recoloured"]
            saved_by_name = Dict(c["name"] => c for c in reload["categories"])
            @test saved_by_name["Protozoa"]["filter"] == "protist"
            @test saved_by_name["Pathogens"]["filter"] == "bacteria"
            @test saved_by_name["Pathogens"]["funcdb_require"]["human_pathogen"] == "yes"
            ## Category order is stable (OrderedDict write).
            @test [c["name"] for c in reload["categories"]] == ["Protozoa", "Pathogens"]

            ## CRITICAL 3 guard: the saved set round-trips through the library,
            ## so it now appears in the listing (previously it was written to a
            ## directory the listing route never read).
            listed = SV._list_category_sets()
            @test any(s -> s["name"] == "recoloured", listed)

            ## An invalid colour is rejected without touching the library.
            bad = SV._save_category_set("bad", "base", Dict("Protozoa" => "blue"))
            @test bad.status == 400
            @test JSON3.read(String(bad.body))["error"] == "invalid_colour"
            @test !haskey(SV._library()["sets"], "bad")

            ## A missing base set is a 404.
            nob = SV._save_category_set("x", "absent", Dict{String,String}())
            @test nob.status == 404
            @test JSON3.read(String(nob.body))["error"] == "base_not_found"

            ## Delete removes the set from the library and returns the name.
            @test haskey(SV._library()["sets"], "recoloured")
            del = SV._delete_category_set("recoloured")
            @test del == "recoloured"
            @test !haskey(SV._library()["sets"], "recoloured")
            ## ...and it drops out of the listing too.
            @test !any(s -> s["name"] == "recoloured", SV._list_category_sets())

            ## Deleting an absent set is a 404.
            del2 = SV._delete_category_set("recoloured")
            @test del2.status == 404
            @test JSON3.read(String(del2.body))["error"] == "set_not_found"

            ## `default` is protected even if present in the library.
            lib = SV._library()
            lib["sets"]["default"] = Dict{String,Any}("label" => "Default", "categories" => [])
            SV._write_library(lib)
            deld = SV._delete_category_set("default")
            @test deld.status == 400
            @test JSON3.read(String(deld.body))["error"] == "protected_set"
            @test haskey(SV._library()["sets"], "default")
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## Feature: Unassigned colour is persisted and resolved through the category set.
    @testset "unassigned colour" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            mkpath(joinpath(tmp, "config"))
            write(joinpath(tmp, "config", "composition.yml"), """
            filters:
              fungi:
                filters:
                  - { column: Domain, pattern: Fungi, action: keep }
            sets:
              base:
                label: Base
                description: test
                categories:
                  - name: Fungi
                    colour: "#f1c40f"
                    filter: fungi
            """)

            # Saving an "Unassigned" colour writes the top-level field, not a category.
            saved = SV._save_category_set("recol", "base",
                Dict("Unassigned" => "#112233", "Fungi" => "#abcdef"))
            @test saved["unassigned_colour"] == "#112233"
            on_disk = SV._library()["sets"]["recol"]
            @test on_disk["unassigned_colour"] == "#112233"
            @test all(c -> get(c, "name", "") != "Unassigned", on_disk["categories"])
            @test SV._category_set_summary("recol", on_disk)["unassigned_colour"] == "#112233"
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## The chart path memoises the parsed library, and a stale hit would render a
    ## figure against superseded categories. The rewrite here is the adversarial
    ## case: same byte count, and immediately after the first, so neither the
    ## file's size nor its mtime distinguishes the two documents. Only a
    ## content-keyed cache survives it.
    @testset "chart library cache invalidates on rewrite" begin
        tmp = mktempdir()
        try
            SV.ServerState.set_root!(tmp)
            path = joinpath(tmp, "config", "composition.yml")
            mkpath(dirname(path))

            write(path, "filters: {}\nsets:\n  aaa:\n    categories: []\n")
            @test haskey(SV._chart_library()["sets"], "aaa")

            size_before = filesize(path)
            write(path, "filters: {}\nsets:\n  bbb:\n    categories: []\n")
            @test filesize(path) == size_before
            @test haskey(SV._chart_library()["sets"], "bbb")
            @test !haskey(SV._chart_library()["sets"], "aaa")
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

end
