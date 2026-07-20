# Unit tests for the databases library: load, normalise, serialise, validate.
using MetaManifold.DatabasesLibrary

@testset "DatabasesLibrary" begin

    ## Round-trip: the canonical shape must serialise back to the native file
    ## shape byte-compatibly in structure, so no other reader in the codebase
    ## changes on account of the editor.
    @testset "normalise and to_yaml_doc round-trip" begin
        native = Dict{String,Any}(
            "databases" => Dict{String,Any}(
                "dir" => "./databases",
                "pr2" => Dict{String,Any}(
                    "dada2"   => Dict{String,Any}("uri" => "u1", "local" => nothing, "remote_path" => nothing),
                    "vsearch" => Dict{String,Any}("uri" => "u2", "local" => nothing),
                    "levels"  => Any["Domain", "Genus"],
                    "vsearch_format" => "pr2",
                    "corrections" => Any[Dict{String,Any}(
                        "source" => "Division", "target" => "Supergroup",
                        "values" => Dict{String,Any}("Rhizaria" => "Rhizaria"))])))

        doc = DatabasesLibrary.normalise(native)
        @test doc["dir"] == "./databases"
        @test length(doc["databases"]) == 1
        entry = doc["databases"][1]
        @test entry["key"] == "pr2"
        @test entry["levels"] == Any["Domain", "Genus"]
        @test entry["vsearch_format"] == "pr2"
        # corrections values become ordered from/to rows: a map keyed by edited
        # text collapses two rows the moment one name is typed into the other.
        @test entry["corrections"][1]["values"] == Any[Dict("from" => "Rhizaria", "to" => "Rhizaria")]

        back = DatabasesLibrary.to_yaml_doc(doc)
        @test back["databases"]["dir"] == "./databases"
        @test back["databases"]["pr2"]["levels"] == Any["Domain", "Genus"]
        @test back["databases"]["pr2"]["vsearch_format"] == "pr2"
        @test back["databases"]["pr2"]["corrections"][1]["values"] == Dict("Rhizaria" => "Rhizaria")
        @test back["databases"]["pr2"]["dada2"]["uri"] == "u1"
    end

    ## remote_path is a pre-existing path on the remote taxonomy host: dada2.jl
    ## reads it to skip transferring a multi-gigabyte database over the wire.
    ## The fixture above sets it to `nothing`, which is indistinguishable from
    ## absent, so it cannot catch to_yaml_doc silently dropping the field; this
    ## one sets it (and label) to a real, non-empty value.
    @testset "normalise and to_yaml_doc round-trip: non-null remote_path and label" begin
        native = Dict{String,Any}(
            "databases" => Dict{String,Any}(
                "dir" => "./databases",
                "pr2" => Dict{String,Any}(
                    "label"   => "PR2 18S",
                    "dada2"   => Dict{String,Any}("uri" => "u1", "local" => nothing,
                                                  "remote_path" => "/remote/pr2/dada2.fa.gz"),
                    "vsearch" => Dict{String,Any}("uri" => "u2", "local" => nothing),
                    "levels"  => Any["Domain", "Genus"],
                    "vsearch_format" => "pr2",
                    "corrections" => Any[])))

        doc = DatabasesLibrary.normalise(native)
        entry = doc["databases"][1]
        @test entry["label"] == "PR2 18S"
        @test entry["dada2"]["remote_path"] == "/remote/pr2/dada2.fa.gz"

        back = DatabasesLibrary.to_yaml_doc(doc)
        @test back["databases"]["pr2"]["label"] == "PR2 18S"
        @test back["databases"]["pr2"]["dada2"]["remote_path"] == "/remote/pr2/dada2.fa.gz"
    end

    ## `dir` lifts out of the entry namespace, which is what makes "no database
    ## may be called dir" structural rather than a bare continue in a loop.
    @testset "dir is not a database" begin
        doc = DatabasesLibrary.normalise(
            Dict("databases" => Dict("dir" => "/tmp/db", "pr2" => Dict("levels" => Any["Domain"]))))
        @test doc["dir"] == "/tmp/db"
        @test DatabasesLibrary.database_keys(doc) == ["pr2"]
    end

    ## levels_of feeds the editor's correction-level dropdown; a stub that always
    ## returns String[] would pass every other test in this file, so it needs
    ## its own direct coverage.
    @testset "levels_of" begin
        doc = DatabasesLibrary.normalise(Dict{String,Any}(
            "databases" => Dict{String,Any}(
                "dir" => "./databases",
                "pr2" => Dict{String,Any}("levels" => Any["Domain", "Kingdom", "Genus"]))))
        @test DatabasesLibrary.levels_of(doc, "pr2") == ["Domain", "Kingdom", "Genus"]
        @test DatabasesLibrary.levels_of(doc, "nope") == String[]
    end

    @testset "load" begin
        tmp = mktempdir()
        try
            # A missing file is an empty document: a fresh install behaves as
            # though no databases are defined rather than erroring.
            @test DatabasesLibrary.database_keys(DatabasesLibrary.load(joinpath(tmp, "nope.yml"))) == String[]

            # An unparseable file RAISES rather than degrading to empty. Degrading
            # would be silent data loss: the editor would render a corrupt file as
            # "no databases", an empty document breaks no rule, and the next Save
            # would overwrite the real config with nothing.
            bad = joinpath(tmp, "bad.yml")
            write(bad, "databases: [unterminated\n")
            @test_throws Exception DatabasesLibrary.load(bad)

            good = joinpath(tmp, "good.yml")
            write(good, "databases:\n  dir: ./d\n  pr2:\n    levels:\n      - Domain\n")
            @test DatabasesLibrary.database_keys(DatabasesLibrary.load(good)) == ["pr2"]
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## A file that PARSES but is not a databases document used to launder into a
    ## valid EMPTY document, which the write gate then could not tell from a
    ## deliberate deletion: GET rendered "no databases", the user pressed Save,
    ## and the real config was wiped. None of `databases: ~`, a misspelt
    ## top-level key or a top-level list broke a single validation rule. The
    ## guard load already documented for UNPARSEABLE YAML now covers the
    ## structurally-wrong file too: the write gate's refusal to coerce a
    ## malformed section guards the REQUEST path, but the FILE path arrived
    ## already laundered, so the gate never fired.
    @testset "load: structurally-wrong file raises rather than emptying" begin
        tmp = mktempdir()
        try
            for (label, body) in (
                    ("a null databases section", "databases: ~\n"),
                    # A misspelt key reads as an ABSENT section, so every
                    # database it holds vanishes exactly as a null one's do.
                    ("a misspelt top-level key", "datbases:\n  dir: ./d\n  pr2:\n    levels: [Domain]\n"),
                    ("a top-level list",         "- just\n- a\n- list\n"),
                    ("a top-level scalar",       "just a string\n"),
                    ("a scalar databases",       "databases: oops\n"),
                    ("a list databases",         "databases:\n  - pr2\n"),
                    ("an empty file",            ""))
                p = joinpath(tmp, "databases.yml")
                write(p, body)
                @test_throws Exception DatabasesLibrary.load(p)
            end

            # The legitimate cases must keep working. An EMPTY-BUT-PRESENT
            # section is a real document, not an error: deleting every database
            # is an edit a user may make, and `databases: {}` is its
            # unambiguous spelling.
            p = joinpath(tmp, "databases.yml")
            write(p, "databases: {}\n")
            @test DatabasesLibrary.database_keys(DatabasesLibrary.load(p)) == String[]
            @test DatabasesLibrary.load(p)["dir"] == "./databases"

            # A `databases:` carrying only `dir` is the same case: `dir` is not
            # a database, and its presence does not make the document non-empty.
            write(p, "databases:\n  dir: ./d\n")
            @test DatabasesLibrary.database_keys(DatabasesLibrary.load(p)) == String[]
            @test DatabasesLibrary.load(p)["dir"] == "./d"

            # `dir` is NOT required: it has a real default, so a document that
            # omits it is complete rather than malformed.
            write(p, "databases:\n  pr2:\n    levels: [Domain]\n")
            @test DatabasesLibrary.database_keys(DatabasesLibrary.load(p)) == ["pr2"]
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## `string(nothing)` is the literal "nothing", and `get` defaults only on an
    ## ABSENT key, never on a present-and-null one. `~` is idiomatic YAML and
    ## this very file spells every `local:` that way, so a null elsewhere in it
    ## is an ordinary hand edit. Each field is handled per its own meaning: a
    ## field with a real default takes that default, and a field whose emptiness
    ## would be malformed is rejected at the write gate.
    @testset "present-and-null fields do not become the string \"nothing\"" begin
        tmp = mktempdir()
        try
            # `dir` has a real default, so `dir: ~` MEANS ./databases. Left to
            # `string` the cache silently became the directory "./nothing", and
            # every multi-gigabyte database re-downloaded into it.
            p = joinpath(tmp, "databases.yml")
            write(p, "databases:\n  dir: ~\n  pr2:\n    levels: [Domain]\n")
            @test DatabasesLibrary.load(p)["dir"] == "./databases"
            doc = DatabasesLibrary.normalise(Dict{String,Any}(
                "databases" => Dict{String,Any}("dir" => nothing,
                                                "pr2" => Dict{String,Any}("levels" => Any["Domain"]))))
            @test doc["dir"] == "./databases"
            # And on the way to disk, from a document the editor sends.
            @test DatabasesLibrary.to_yaml_doc(
                Dict{String,Any}("dir" => nothing, "databases" => Any[]))["databases"]["dir"] == "./databases"

            # A label is optional and its absence is already spelt by omitting
            # the key, so a null label means that omission.
            write(p, "databases:\n  pr2:\n    label: ~\n    levels: [Domain]\n")
            @test DatabasesLibrary.load(p)["databases"][1]["label"] == ""
            native = DatabasesLibrary.to_yaml_doc(Dict{String,Any}("dir" => "./d",
                "databases" => Any[Dict{String,Any}("key" => "pr2", "label" => nothing,
                                                    "levels" => Any["Domain"])]))
            @test !haskey(native["databases"]["pr2"], "label")

            # vsearch_format has a real default too, so a null one means it.
            write(p, "databases:\n  pr2:\n    vsearch_format: ~\n    levels: [Domain]\n")
            @test DatabasesLibrary.load(p)["databases"][1]["vsearch_format"] == "generic"

            # A uri names something to FETCH; absent and null alike mean there
            # is none, which is legitimate when `local:` carries the file.
            write(p, "databases:\n  pr2:\n    dada2:\n      uri: ~\n      local: /tmp/x.gz\n    levels: [Domain]\n")
            @test DatabasesLibrary.load(p)["databases"][1]["dada2"]["uri"] == ""
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    ## A null level and a null correction target are malformed, not defaults:
    ## neither field has a sensible fallback, and each would have reached disk
    ## as the literal label "nothing". Both arrive at validate as blanks, so the
    ## rules that already exist for a blank catch them.
    @testset "validate: a null level or correction target is rejected" begin
        entry(; kw...) = merge(Dict{String,Any}(
            "key" => "pr2", "label" => "",
            "dada2"   => Dict{String,Any}("uri" => "https://example.org/a.gz"),
            "vsearch" => Dict{String,Any}("uri" => "https://example.org/b.gz"),
            "levels"  => Any["Domain"], "vsearch_format" => "pr2",
            "corrections" => Any[]), Dict{String,Any}(String(k) => v for (k, v) in kw))
        doc(e) = Dict{String,Any}("dir" => "./databases", "databases" => Any[e])

        # A null level: `levels: [Domain, ~]` wrote ["Domain", "nothing"].
        errs = DatabasesLibrary.validate(doc(entry(levels = Any["Domain", nothing])))
        @test any(e -> occursin("taxonomy level with no name", e), errs)

        # A null correction value: `Foo: ~` wrote `to: "nothing"`.
        corr = Any[Dict{String,Any}("source" => "Domain", "target" => "Domain",
                                    "values" => Any[Dict{String,Any}("from" => "Foo", "to" => nothing)])]
        errs = DatabasesLibrary.validate(doc(entry(corrections = corr)))
        @test any(e -> occursin("no target label", e), errs)
        # A blank target is the same defect differently spelt.
        corr[1]["values"][1]["to"] = "  "
        @test any(e -> occursin("no target label", e),
                  DatabasesLibrary.validate(doc(entry(corrections = corr))))
        # A real target still validates, so the rule has not swallowed the
        # legitimate case.
        corr[1]["values"][1]["to"] = "Rhizaria"
        @test isempty(DatabasesLibrary.validate(doc(entry(corrections = corr))))

        # A null source label is the blank-source case, not a label reading
        # "nothing" that would have collapsed a row on the way to disk.
        corr[1]["values"][1]["from"] = nothing
        @test any(e -> occursin("no source label", e),
                  DatabasesLibrary.validate(doc(entry(corrections = corr))))
    end

    ## validate stripped a database key while to_yaml_doc wrote it raw, so the
    ## two described different documents: "pr2 " passed the blank, dir and
    ## duplicate rules as "pr2" and landed on disk as `"pr2 ":`, whereupon
    ## make_db_meta's haskey(db_cfg, "pr2") missed it and every run broke.
    @testset "an untrimmed database key reaches disk trimmed" begin
        e(key) = Dict{String,Any}("key" => key, "label" => "",
            "dada2"   => Dict{String,Any}("uri" => "https://example.org/a.gz"),
            "vsearch" => Dict{String,Any}("uri" => "https://example.org/b.gz"),
            "levels"  => Any["Domain"], "vsearch_format" => "pr2", "corrections" => Any[])
        doc = Dict{String,Any}("dir" => "./databases", "databases" => Any[e("pr2 ")])

        # validate accepts it, reading the key as "pr2"...
        @test isempty(DatabasesLibrary.validate(doc))
        # ...and to_yaml_doc now writes the same key it was judged by, so the
        # readers downstream find it.
        native = DatabasesLibrary.to_yaml_doc(doc)
        @test haskey(native["databases"], "pr2")
        @test !haskey(native["databases"], "pr2 ")

        # Every other reader of the document agrees on the key.
        @test DatabasesLibrary.database_keys(doc) == ["pr2"]
        @test DatabasesLibrary.levels_of(doc, "pr2") == ["Domain"]

        # Trimming can create a collision, and the duplicate rule (which already
        # compares trimmed keys) is what refuses it, so no entry is ever
        # silently dropped by being re-keyed onto another.
        clash = Dict{String,Any}("dir" => "./databases", "databases" => Any[e("pr2"), e("pr2 ")])
        @test any(x -> occursin("duplicate database name 'pr2'", x),
                  DatabasesLibrary.validate(clash))
    end

    ## Write-time rules. Each is meaningless or destructive in a NEW document but
    ## would fail a databases.yml that validates today, so it lives here and not
    ## in the shared rule function.
    @testset "validate: write-time rules" begin
        base(; kw...) = begin
            e = Dict{String,Any}("key" => "pr2", "label" => "",
                                 "dada2"   => Dict{String,Any}("uri" => "https://example.org/a.gz"),
                                 "vsearch" => Dict{String,Any}("uri" => "https://example.org/b.gz"),
                                 "levels"  => Any["Domain", "Genus"],
                                 "vsearch_format" => "pr2",
                                 "corrections" => Any[])
            for (k, v) in kw; e[string(k)] = v; end
            Dict{String,Any}("dir" => "./d", "databases" => Any[e])
        end

        @test isempty(DatabasesLibrary.validate(base()))

        # A uri names something to fetch, and the download route hands it to
        # Downloads.download, which is libcurl-backed and honours file:// among
        # others. Left unchecked, a save could read any file the server can read
        # and cache it where the files route would serve it back.
        @test !isempty(DatabasesLibrary.validate(
            base(dada2 = Dict{String,Any}("uri" => "file:///etc/passwd"))))
        @test !isempty(DatabasesLibrary.validate(
            base(vsearch = Dict{String,Any}("uri" => "file:///etc/passwd"))))
        @test !isempty(DatabasesLibrary.validate(
            base(dada2 = Dict{String,Any}("uri" => "ftp://example.org/a.gz"))))
        @test isempty(DatabasesLibrary.validate(
            base(dada2 = Dict{String,Any}("uri" => "http://example.org/a.gz"))))

        # remote_path reaches the command string that ssh runs through a login
        # shell on the remote taxonomy host, so a metacharacter there is remote
        # command execution. A file path never legitimately carries one.
        @test !isempty(DatabasesLibrary.validate(base(
            dada2 = Dict{String,Any}("uri" => "https://example.org/a.gz",
                                     "remote_path" => "/tmp/x.gz; touch /tmp/pwned; #"))))
        @test !isempty(DatabasesLibrary.validate(base(
            dada2 = Dict{String,Any}("uri" => "https://example.org/a.gz",
                                     "remote_path" => "/tmp/\$(id).gz"))))
        @test !isempty(DatabasesLibrary.validate(base(
            dada2 = Dict{String,Any}("uri" => "https://example.org/a.gz",
                                     "remote_path" => "/tmp/x`id`.gz"))))
        # An ordinary remote path, including one with a space, still passes.
        @test isempty(DatabasesLibrary.validate(base(
            dada2 = Dict{String,Any}("uri" => "https://example.org/a.gz",
                                     "remote_path" => "/mnt/mokosz/home/joshua/pr2 v5.fa.gz"))))
        # vsearch has no remote stage, so it carries no remote_path to check.
        @test isempty(DatabasesLibrary.validate(base(
            vsearch = Dict{String,Any}("uri" => "https://example.org/b.gz",
                                       "remote_path" => "; touch /tmp/pwned"))))

        # A key may not be blank, duplicated, or `dir`.
        @test any(occursin("name", e) for e in DatabasesLibrary.validate(base(key = "")))
        @test any(occursin("dir", e) for e in DatabasesLibrary.validate(base(key = "dir")))
        dup = base()
        push!(dup["databases"], deepcopy(dup["databases"][1]))
        @test any(occursin("duplicate", lowercase(e)) for e in DatabasesLibrary.validate(dup))

        # levels feeds noncounts and the taxonomy columns in merge_taxa: empty
        # yields a database with no taxonomy, a duplicate silently does nothing.
        @test !isempty(DatabasesLibrary.validate(base(levels = Any[])))
        @test any(occursin("duplicate", lowercase(e))
                  for e in DatabasesLibrary.validate(base(levels = Any["Domain", "Domain"])))

        # Each level must carry a name, and the names are compared TRIMMED. The
        # editor has always marked both of these red, but the gate accepted them:
        # `isempty` tests the LIST rather than the names, and `unique` over the
        # raw names sees "Genus" and "Genus " as two ranks. So a user saved
        # successfully DESPITE a red field, and a blank name reached the YAML as a
        # taxonomy column of no name while a trim-duplicate reached it as a silent
        # no-op. Mark, gate and backend now agree on one rule.
        @test any(occursin("no name", e)
                  for e in DatabasesLibrary.validate(base(levels = Any["Kingdom", "", "Genus"])))
        @test any(occursin("no name", e)
                  for e in DatabasesLibrary.validate(base(levels = Any["Kingdom", "   ", "Genus"])))
        @test any(occursin("duplicate", lowercase(e))
                  for e in DatabasesLibrary.validate(base(levels = Any["Genus", "Genus "])))
        # A level list that is merely untidy, not ambiguous, still passes: the
        # rule is about blankness and collision, not about whitespace as such.
        @test isempty(DatabasesLibrary.validate(base(levels = Any["Domain", "Genus"])))

        # vsearch_format is a two-way switch: make_db_meta defaults it to
        # "generic" and only the literal "pr2" selects pipe-parsing, so free text
        # means "PR2" silently degrades to generic parsing and mislabels
        # every assignment.
        @test isempty(DatabasesLibrary.validate(base(vsearch_format = "generic")))
        @test !isempty(DatabasesLibrary.validate(base(vsearch_format = "PR2")))
        @test !isempty(DatabasesLibrary.validate(base(vsearch_format = "silva")))

        # A format with neither uri nor local can never resolve. A local path
        # alone is enough, and it need not name a file that exists yet: the write
        # gate no longer asks, so the path may be saved before the file arrives.
        @test !isempty(DatabasesLibrary.validate(base(dada2 = Dict{String,Any}())))
        @test isempty(DatabasesLibrary.validate(base(dada2 = Dict{String,Any}("local" => "/no/such/file"))))

        # merge_taxa silently skips a correction whose columns are absent from the
        # frame, so a correction naming a non-level would quietly do nothing.
        @test !isempty(DatabasesLibrary.validate(base(corrections = Any[
            Dict{String,Any}("source" => "Nope", "target" => "Genus", "values" => Any[])])))
        @test isempty(DatabasesLibrary.validate(base(corrections = Any[
            Dict{String,Any}("source" => "Domain", "target" => "Genus", "values" => Any[])])))

        # to_yaml_doc re-keys a correction's values by `from` on the way to disk, so
        # the same hazard the ordered from/to rows exist to prevent reappears one
        # level down: a blank `from` has nowhere to go and two rows sharing one
        # collapse into a single entry, silently discarding a correction. Neither is
        # caught anywhere else, so this is the only gate standing between the editor
        # and a save that quietly loses a row.
        @test any(occursin("no source label", e) for e in DatabasesLibrary.validate(base(corrections = Any[
            Dict{String,Any}("source" => "Domain", "target" => "Genus", "values" => Any[
                Dict{String,Any}("from" => "", "to" => "x")])])))
        @test any(occursin("duplicate source label", e) for e in DatabasesLibrary.validate(base(corrections = Any[
            Dict{String,Any}("source" => "Domain", "target" => "Genus", "values" => Any[
                Dict{String,Any}("from" => "Bacteria", "to" => "x"),
                Dict{String,Any}("from" => "Bacteria", "to" => "y")])])))
        @test isempty(DatabasesLibrary.validate(base(corrections = Any[
            Dict{String,Any}("source" => "Domain", "target" => "Genus", "values" => Any[
                Dict{String,Any}("from" => "Bacteria", "to" => "x"),
                Dict{String,Any}("from" => "Archaea", "to" => "y")])])))
    end

    ## A present-but-null section is not the same as an absent one: `get`
    ## returns the default only when the key is absent, so a null section
    ## reaches an unguarded iteration as `nothing`. The read-side functions
    ## below (to_yaml_doc, database_keys, levels_of) back a write gate where a
    ## throw is a bare 500 rather than an actionable 400, so they must degrade
    ## to an empty document instead of throwing. validate is different: a null
    ## (or otherwise malformed) top-level `databases` is REJECTED, not
    ## coerced, because coercing it would let a write silently wipe every
    ## database. See "validate: malformed top-level sections are rejected"
    ## below for that gate.
    @testset "present-but-null sections do not throw" begin
        # A null "databases" does not throw: to_yaml_doc, database_keys and
        # levels_of all degrade to an empty reading rather than erroring, which
        # is what lets validate (tested separately) safely inspect the same
        # malformed document and reject it without a 500.
        null_databases = Dict{String,Any}("dir" => "./d", "databases" => nothing)
        @test DatabasesLibrary.to_yaml_doc(null_databases) ==
            Dict{String,Any}("databases" => Dict{String,Any}("dir" => "./d"))
        @test DatabasesLibrary.database_keys(null_databases) == String[]
        @test DatabasesLibrary.levels_of(null_databases, "pr2") == String[]

        # The uris are incidental here, but they must be fetchable ones: this
        # testset asserts the document is otherwise clean, so a placeholder uri
        # would trip the scheme rule and confound the null-corrections assertion.
        null_corrections = Dict{String,Any}("dir" => "./d", "databases" => Any[
            Dict{String,Any}("key" => "pr2", "label" => "",
                             "dada2"   => Dict{String,Any}("uri" => "https://example.org/a.gz"),
                             "vsearch" => Dict{String,Any}("uri" => "https://example.org/b.gz"),
                             "levels"  => Any["Domain", "Genus"],
                             "vsearch_format" => "pr2",
                             "corrections" => nothing)])
        @test isempty(DatabasesLibrary.validate(null_corrections))
        @test DatabasesLibrary.to_yaml_doc(null_corrections)["databases"]["pr2"]["corrections"] == Any[]
    end

    ## A malformed top-level `databases` used to pass validate cleanly (since
    ## _seq coerced it to an empty sequence before iteration), so a PUT with
    ## `databases: null` returned 200 and wrote a document with zero database
    ## entries: a real config wiped in one request. Deleting every database
    ## already has an unambiguous spelling, the empty list, so validate now
    ## rejects everything else instead of coercing it.
    @testset "validate: malformed top-level sections are rejected" begin
        for bad in (nothing, "oops", 42, Dict{String,Any}("pr2" => 1))
            doc = Dict{String,Any}("dir" => "./d", "databases" => bad)
            errs = DatabasesLibrary.validate(doc)
            @test !isempty(errs)
            @test any(occursin("databases section must be a list", e) for e in errs)
        end

        # Absent is the same shape as null: no `databases` key at all.
        absent = Dict{String,Any}("dir" => "./d")
        @test !isempty(DatabasesLibrary.validate(absent))

        # `dir` is likewise rejected when it is not a string: a mapping or a
        # list there would serialise nonsense into the databases: namespace.
        for bad_dir in (Dict{String,Any}("x" => 1), Any[1, 2], 42)
            doc = Dict{String,Any}("dir" => bad_dir, "databases" => Any[])
            errs = DatabasesLibrary.validate(doc)
            @test !isempty(errs)
            @test any(occursin("dir must be a string", e) for e in errs)
        end

        # A blank dir is rejected. normalise defaults `dir` only when the key is
        # ABSENT and the editor always sends the field, so the "./databases"
        # placeholder is a default a cleared field never gets: to_yaml_doc writes
        # `dir: ""` verbatim and _db_info's abspath("") resolves the cache to the
        # working directory. Clearing the field silently relocated every download
        # to the repository root.
        for blank in ("", "   ", "\t")
            errs = DatabasesLibrary.validate(Dict{String,Any}("dir" => blank, "databases" => Any[]))
            @test any(occursin("dir must not be blank", e) for e in errs)
        end

        # An ABSENT dir is not blank: normalise and to_yaml_doc both default it.
        @test isempty(DatabasesLibrary.validate(Dict{String,Any}("databases" => Any[])))

        # The legitimate empty case still validates cleanly: removing every
        # database is allowed, it is warned about at the route layer, not
        # blocked here.
        @test isempty(DatabasesLibrary.validate(Dict{String,Any}("dir" => "./d", "databases" => Any[])))
    end

    ## The shared STRUCTURAL rules still apply through validate; the environment
    ## rule deliberately does not. A save carries the whole document, so a local:
    ## whose file has since moved must not reject an edit to a different entry,
    ## and the write gate must not answer whether an arbitrary server path
    ## exists. Validation._validate_databases still reports the absent file; see
    ## test_validation.jl.
    @testset "validate: a missing local file is not a write-time error" begin
        doc(local_path) = Dict{String,Any}("dir" => "./d", "databases" => Any[
            Dict{String,Any}("key" => "pr2", "label" => "",
                             "dada2"   => Dict{String,Any}("local" => local_path),
                             "vsearch" => Dict{String,Any}("uri" => "https://example.org/b.gz"),
                             "levels"  => Any["Domain"],
                             "vsearch_format" => "pr2", "corrections" => Any[])])

        @test isempty(DatabasesLibrary.validate(doc("/no/such/file")))

        # The gate must be silent on a path's existence either way: an error for
        # one and none for the other is an oracle any client can query.
        present = tempname()
        write(present, "")
        try
            @test DatabasesLibrary.validate(doc(present)) ==
                  DatabasesLibrary.validate(doc("/no/such/file"))
        finally
            rm(present; force=true)
        end
    end
end
