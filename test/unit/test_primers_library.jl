# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).
using Test
using MetaManifold.PrimersLibrary

@testset "PrimersLibrary" begin

    @testset "normalise: native pairs to canonical shape" begin
        raw = Dict("Forward" => Dict("F1" => "ACGT"),
                   "Reverse" => Dict("R1" => "TGCA"),
                   "Pairs"   => [Dict("P1" => ["F1", "R1"])])
        doc = PrimersLibrary.normalise(raw)
        @test doc["Forward"]["F1"] == "ACGT"
        @test doc["Pairs"] == [Dict("name" => "P1", "forward" => "F1", "reverse" => "R1")]
    end

    @testset "normalise: numeric names survive as strings" begin
        # An unquoted numeric name parses as Int64 under YAML; a later
        # name-keyed lookup would dangle unless coerced at the boundary.
        raw = Dict("Forward" => Dict(515 => "ACGT"),
                   "Reverse" => Dict("R1" => "TGCA"),
                   "Pairs"   => [Dict(9 => [515, "R1"])])
        doc = PrimersLibrary.normalise(raw)
        @test haskey(doc["Forward"], "515")
        @test doc["Pairs"][1] == Dict("name" => "9", "forward" => "515", "reverse" => "R1")
    end

    @testset "load: absent file yields empty document" begin
        doc = PrimersLibrary.load(joinpath(mktempdir(), "nope.yml"))
        @test doc["Forward"] == Dict{String,Any}()
        @test doc["Reverse"] == Dict{String,Any}()
        @test doc["Pairs"] == Any[]
    end

    @testset "load: unparseable file raises rather than emptying" begin
        # Degrading a corrupt file to an empty document would be silent data
        # loss: the editor would show "no primers", an empty document breaks no
        # validation rule, and the next Save would overwrite the real primers
        # with nothing. Raising is the safe behaviour; the routes catch it and
        # report the file as unreadable.
        p = joinpath(mktempdir(), "primers.yml")
        write(p, "Forward: [unclosed\n  - a\n")
        @test_throws Exception PrimersLibrary.load(p)
    end

    ## A file that PARSES but is not a primers document used to launder into a
    ## valid EMPTY document, which the write gate then could not tell from a
    ## deliberate deletion: GET rendered "no primers", the user pressed Save,
    ## and the real config was wiped. `Pairs: ~` wiped every pair and
    ## `Forward: ~` every forward primer, and neither broke a validation rule.
    ## The guard load already documented for UNPARSEABLE YAML now covers the
    ## structurally-wrong file too: the write gate's refusal to coerce a
    ## malformed section guards the REQUEST path, but the FILE path arrived
    ## already laundered, so the gate never fired.
    @testset "load: structurally-wrong file raises rather than emptying" begin
        tmp = mktempdir()
        try
            for (label, body) in (
                    ("a top-level list",   "- just\n- a\n- list\n"),
                    ("a top-level scalar", "just a string\n"),
                    ("a null Pairs",       "Forward: {}\nReverse: {}\nPairs: ~\n"),
                    ("a null Forward",     "Forward: ~\nReverse: {}\nPairs: []\n"),
                    ("a null Reverse",     "Forward: {}\nReverse: ~\nPairs: []\n"),
                    ("a scalar Pairs",     "Forward: {}\nReverse: {}\nPairs: oops\n"),
                    # A misspelt section reads as an ABSENT one, so the pairs it
                    # was meant to name vanish exactly as a null section's do.
                    ("a misspelt Pairs",   "Forward: {}\nReverse: {}\nPares: []\n"),
                    ("a missing Forward",  "Reverse: {}\nPairs: []\n"))
                p = joinpath(tmp, "primers.yml")
                write(p, body)
                @test_throws Exception PrimersLibrary.load(p)
            end

            # The legitimate cases must keep working. An EMPTY-BUT-PRESENT
            # section is a real document, not an error: the empty list and the
            # empty mapping are the unambiguous spellings of "no pairs" and "no
            # primers", and deleting everything is an edit a user may make.
            p = joinpath(tmp, "primers.yml")
            write(p, "Forward: {}\nReverse: {}\nPairs: []\n")
            doc = PrimersLibrary.load(p)
            @test doc["Forward"] == Dict{String,Any}()
            @test doc["Pairs"] == Any[]

            # A real document still loads.
            write(p, "Forward:\n  F1: ACGT\nReverse:\n  R1: TGCA\nPairs:\n  - P1:\n    - F1\n    - R1\n")
            @test PrimersLibrary.pair_names(PrimersLibrary.load(p)) == ["P1"]
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## The worst of the class. primers.yml indents a pair's members level with
    ## their key, so one missing "- " fuses the following pair into the SAME
    ## mapping. _flatten_pair returned on the FIRST key and discarded the rest
    ## silently; a mapping iterates in hash order, so which pair was destroyed
    ## was not even predictable. validate could not catch it because it
    ## validates the ALREADY-LOSSY document, and the shared rule function
    ## (which iterates every key of the entry) saw both pairs, so the two
    ## readers of one file contradicted each other.
    @testset "load: a fused pair entry loses no pair" begin
        tmp = mktempdir()
        try
            p = joinpath(tmp, "primers.yml")
            # Verbatim: the "- " before TarEuk is missing, so YAML parses Pairs
            # as a ONE-element list holding a TWO-key mapping.
            write(p, """
            Forward:
              EMP515F: "GTGYCAGCMGCCGCGGTAA"
              TarEukF: "CCAGCASCYGCGGTAATTCC"
            Reverse:
              EMP806R: "GGACTACNVGGGTWTCTAAT"
              TarEukR: "ACTTTCGTTCTTGATYRA"
            Pairs:
              - EMP:
                - EMP515F
                - EMP806R
                TarEuk:
                - TarEukF
                - TarEukR
            """)
            doc = PrimersLibrary.load(p)
            # Both pairs survive the load, so the editor shows the user both.
            @test Set(PrimersLibrary.pair_names(doc)) == Set(["EMP", "TarEuk"])
            # And both survive a Save, which rewrites them one mapping per pair.
            native = PrimersLibrary.to_yaml_doc(doc)
            @test length(native["Pairs"]) == 2
            @test Set(only(collect(keys(e))) for e in native["Pairs"]) == Set(["EMP", "TarEuk"])
            @test PrimersLibrary.normalise(native)["Pairs"] == doc["Pairs"]
            # Each keeps its own members: a survivor wearing the other's
            # sequences would pass the name check above.
            byname = Dict(p["name"] => p for p in doc["Pairs"])
            @test byname["EMP"]["forward"] == "EMP515F"
            @test byname["EMP"]["reverse"] == "EMP806R"
            @test byname["TarEuk"]["forward"] == "TarEukF"
            @test byname["TarEuk"]["reverse"] == "TarEukR"
            # The document is not malformed once every pair is surfaced, so the
            # save is allowed to proceed and repair the file.
            @test isempty(PrimersLibrary.validate(doc))
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## `string(nothing)` is the literal "nothing", so an idiomatic YAML null
    ## would be written back as that four-letter string rather than as the
    ## absence it spells.
    @testset "a null name or member does not become the string \"nothing\"" begin
        doc = PrimersLibrary.normalise(Dict{String,Any}(
            "Forward" => Dict{String,Any}("F1" => "ACGT"),
            "Reverse" => Dict{String,Any}("R1" => "TGCA"),
            "Pairs"   => Any[Dict{String,Any}("P1" => Any[nothing, "R1"])]))
        @test doc["Pairs"][1]["forward"] == ""
        @test doc["Pairs"][1]["reverse"] == "R1"
        native = PrimersLibrary.to_yaml_doc(Dict{String,Any}(
            "Forward" => Dict{String,Any}(), "Reverse" => Dict{String,Any}(),
            "Pairs"   => Any[Dict{String,Any}("name" => nothing, "forward" => nothing,
                                              "reverse" => nothing)]))
        @test native["Pairs"] == Any[Dict{String,Any}("" => Any["", ""])]
    end

    @testset "validate: empty sequence rejected at the write gate only" begin
        # An empty sequence passes the shared character check vacuously, and the
        # editor's "+ Primer" makes creating one a single click. It is rejected
        # here, where new documents are written, but NOT in the shared rules,
        # which would fail an existing primers.yml that validated yesterday.
        doc = Dict{String,Any}(
            "Forward" => Dict{String,Any}("F1" => ""),
            "Reverse" => Dict{String,Any}("R1" => "TGCA"),
            "Pairs"   => Any[])
        @test any(e -> occursin("empty sequence", e), PrimersLibrary.validate(doc))
        # The shared rule function, used by the environment validator, still accepts it.
        @test isempty(MetaManifold.Validation.primer_document_errors(
            Dict("Forward" => Dict("F1" => ""), "Reverse" => Dict("R1" => "TGCA"), "Pairs" => [])))
        # A whitespace-only sequence is empty too.
        doc["Forward"]["F1"] = "   "
        @test any(e -> occursin("empty sequence", e), PrimersLibrary.validate(doc))
        # A real sequence is untouched.
        doc["Forward"]["F1"] = "ACGT"
        @test isempty(PrimersLibrary.validate(doc))
    end

    @testset "to_yaml_doc round-trips through normalise" begin
        doc = Dict{String,Any}(
            "Forward" => Dict{String,Any}("F1" => "ACGT"),
            "Reverse" => Dict{String,Any}("R1" => "TGCA"),
            "Pairs"   => Any[Dict{String,Any}("name" => "P1", "forward" => "F1", "reverse" => "R1")])
        native = PrimersLibrary.to_yaml_doc(doc)
        @test native["Pairs"] == [Dict("P1" => ["F1", "R1"])]
        @test PrimersLibrary.normalise(native)["Pairs"] == doc["Pairs"]
    end

    ## A present-but-null Pairs is not the same as an absent one: `get` returns
    ## the default only when the key is absent, so a null section reaches an
    ## unguarded iteration as `nothing`. to_yaml_doc and pair_names back a
    ## write gate where a throw is a bare 500 rather than an actionable 400,
    ## so they degrade to an empty reading instead of throwing. validate is
    ## different: a null (or otherwise malformed) top-level Pairs is REJECTED,
    ## not coerced, because coercing it would let a write silently wipe every
    ## pair. See "validate: malformed top-level sections are rejected" below.
    @testset "present-but-null Pairs does not throw" begin
        doc = Dict{String,Any}("Forward" => Dict{String,Any}(),
                               "Reverse" => Dict{String,Any}(),
                               "Pairs"   => nothing)
        @test PrimersLibrary.to_yaml_doc(doc) == Dict{String,Any}(
            "Forward" => Dict{String,Any}(), "Reverse" => Dict{String,Any}(), "Pairs" => Any[])
        @test PrimersLibrary.pair_names(doc) == String[]
    end

    ## A malformed top-level Pairs used to pass validate cleanly (since _seq
    ## coerced it to an empty sequence before iteration), so a PUT with
    ## `Pairs: null` returned 200 and wrote a document with zero pairs: a real
    ## primers.yml wiped in one request. Deleting every pair already has an
    ## unambiguous spelling, the empty list, so validate now rejects
    ## everything else instead of coercing it. Forward and Reverse get the
    ## same treatment: a scalar or a list there would serialise nonsense.
    @testset "validate: malformed top-level sections are rejected" begin
        for bad in (nothing, "oops", 42, Dict{String,Any}("P1" => Any["F1", "R1"]))
            doc = Dict{String,Any}("Forward" => Dict{String,Any}("F1" => "ACGT"),
                                   "Reverse" => Dict{String,Any}("R1" => "TGCA"),
                                   "Pairs"   => bad)
            errs = PrimersLibrary.validate(doc)
            @test !isempty(errs)
            @test any(occursin("Pairs section must be a list", e) for e in errs)
        end

        # Absent is the same shape as null: no Pairs key at all.
        absent = Dict{String,Any}("Forward" => Dict{String,Any}(), "Reverse" => Dict{String,Any}())
        @test !isempty(PrimersLibrary.validate(absent))

        for section in ("Forward", "Reverse")
            for bad in (nothing, "oops", 42, Any["x"])
                doc = Dict{String,Any}("Forward" => Dict{String,Any}(),
                                       "Reverse" => Dict{String,Any}(), "Pairs" => Any[])
                doc[section] = bad
                errs = PrimersLibrary.validate(doc)
                @test !isempty(errs)
                @test any(occursin("$section section must be a mapping", e) for e in errs)
            end
        end

        # The legitimate empty case still validates cleanly: removing every
        # pair (and every primer) is allowed, not blocked here.
        @test isempty(PrimersLibrary.validate(Dict{String,Any}(
            "Forward" => Dict{String,Any}(), "Reverse" => Dict{String,Any}(), "Pairs" => Any[])))
    end

    @testset "pair_names in document order" begin
        doc = Dict{String,Any}("Forward" => Dict(), "Reverse" => Dict(),
            "Pairs" => Any[
                Dict("name" => "B", "forward" => "F1", "reverse" => "R1"),
                Dict("name" => "A", "forward" => "F1", "reverse" => "R1")])
        @test PrimersLibrary.pair_names(doc) == ["B", "A"]
    end

end
