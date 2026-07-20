@testset "Validation" begin

    @testset "_validate_primers - valid" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  EMP515F: "GTGYCAGCMGCCGCGGTAA"
Reverse:
  EMP806R: "GGACTACNVGGGTWTCTAAT"
Pairs:
  - EMP:
    - EMP515F
    - EMP806R
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test isempty(errors)
    end

    @testset "_validate_primers - unknown pair member" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  EMP515F: "GTGYCAGCMGCCGCGGTAA"
Reverse:
  EMP806R: "GGACTACNVGGGTWTCTAAT"
Pairs:
  - EMP:
    - EMP515F
    - UnknownR
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test any(e -> occursin("UnknownR", e.message), errors)
    end

    @testset "_validate_primers - invalid base" begin
        tmp = tempname() * ".yml"
        write(tmp, """
Forward:
  BadF: "ATCGXYZ"
Reverse:
  GoodR: "ATCG"
Pairs: []
""")
        errors = Validation.ValidationError[]
        Validation._validate_primers(errors, tmp)
        rm(tmp)
        @test any(e -> occursin("invalid bases", e.message), errors)
    end

    @testset "primer_document_errors" begin
        using MetaManifold.Validation: primer_document_errors

        good = Dict("Forward" => Dict("F1" => "ACGTMRWS"),
                    "Reverse" => Dict("R1" => "TGCAYKVH"),
                    "Pairs"   => [Dict("P1" => ["F1", "R1"])])
        @test isempty(primer_document_errors(good))

        bad_base = Dict("Forward" => Dict("F1" => "ACGTZ"),
                        "Reverse" => Dict("R1" => "TGCA"),
                        "Pairs"   => [])
        @test any(e -> occursin("invalid bases", e), primer_document_errors(bad_base))

        dangling = Dict("Forward" => Dict("F1" => "ACGT"),
                        "Reverse" => Dict("R1" => "TGCA"),
                        "Pairs"   => [Dict("P1" => ["F1", "MISSING"])])
        @test any(e -> occursin("unknown reverse primer", e), primer_document_errors(dangling))

        # A name outside the safe-name charset is accepted: names are only lookup
        # keys, never a path, shell word, or SQL identifier, so rejecting one would
        # fail a primers.yml the pipeline runs perfectly well.
        odd_name = Dict("Forward" => Dict("bad name!" => "ACGT"),
                        "Reverse" => Dict("R1" => "TGCA"),
                        "Pairs"   => [Dict("P1" => ["bad name!", "R1"])])
        @test isempty(primer_document_errors(odd_name))

        # Never throws on a wholly malformed document.
        @test primer_document_errors(Dict("Forward" => "notamap", "Pairs" => "notalist")) isa Vector{String}
    end

    @testset "database_document_errors" begin
        # The shared rule function is the single source of truth for the SHAPE of
        # a databases document, so the environment validator and the write gate
        # cannot disagree on it. It takes the NATIVE shape and never throws.
        @test isempty(Validation.database_document_errors(
            Dict("databases" => Dict("dir" => "./databases",
                                     "pr2" => Dict("levels" => ["Domain"])))))

        # Missing 'databases:' key is the one structural error; pin its exact
        # wording so a reworded or dropped message fails this test.
        @test Validation.database_document_errors(Dict("nope" => 1)) ==
            ["databases.yml missing 'databases:' key"]

        # Whether a local: path names a file that exists is an ENVIRONMENT rule,
        # not a structural one, and it lives in _validate_databases alone (see
        # the testset below). It must not fire from here, because this function
        # also backs the databases write gate, where a save carries the whole
        # document: one local: whose file had since moved rejected every save of
        # every entry, and the resulting 400 told any client whether an arbitrary
        # server path exists.
        @test isempty(Validation.database_document_errors(
            Dict("databases" => Dict("pr2" => Dict("dada2" => Dict("local" => "/no/such/file"))))))
        @test isempty(Validation.database_document_errors(
            Dict("databases" => Dict("pr2" => Dict(
                "dada2"   => Dict("local" => "/no/such/dada2"),
                "vsearch" => Dict("local" => "/no/such/vsearch"))))))

        # Never throws on rubbish, however malformed, and pin the exact
        # (non-)result: a databases: value that is not a mapping is the same
        # structural error as a missing key; a db_cfg that is not a mapping
        # is skipped outright and carries no checkable content.
        @test Validation.database_document_errors(Dict("databases" => "not a mapping")) ==
            ["databases.yml missing 'databases:' key"]
        @test Validation.database_document_errors(Dict("databases" => Dict("pr2" => "scalar"))) ==
            String[]
    end

    ## The local:-file rule, in the one place it belongs. It reports that the
    ## config points at a file that is not there, which is a fact about the
    ## machine rather than about the document, so it is the environment
    ## validator's to report and no write gate's to enforce.
    @testset "_validate_databases: local file existence" begin
        tmp = mktempdir()
        # Run _validate_databases over a databases.yml written from `body` and
        # return its messages, so each case exercises the real entry point rather
        # than the extracted helper.
        function messages(body::String)
            path = joinpath(tmp, "databases.yml")
            write(path, body)
            errs = Validation.ValidationError[]
            Validation._validate_databases(errs, path)
            [e.message for e in errs]
        end
        try
            # Pin the exact message, including the "$db_name.$method.local:"
            # prefix, so dropping the prefix or rewording the message fails here.
            @test messages("databases:\n  pr2:\n    dada2:\n      local: /no/such/file\n") ==
                ["pr2.dada2.local: file not found: /no/such/file"]

            # Both dada2 and vsearch checks must fire independently, and exactly
            # once each: deleting either check, or duplicating the errors list,
            # fails this exact-content, exact-count assertion.
            @test messages("""
                databases:
                  pr2:
                    dada2:
                      local: /no/such/dada2
                    vsearch:
                      local: /no/such/vsearch
                """) == [
                    "pr2.dada2.local: file not found: /no/such/dada2",
                    "pr2.vsearch.local: file not found: /no/such/vsearch",
                ]

            # A file that is there raises nothing.
            present = joinpath(tmp, "pr2.fa")
            write(present, "")
            @test isempty(messages("databases:\n  pr2:\n    dada2:\n      local: $present\n"))

            # `dir` is the shared cache directory, not a database, and must be
            # skipped regardless of its shape. Give it a MAPPING (not a string)
            # that would itself produce an error if the skip rule were removed,
            # so the skip is genuinely exercised rather than vacuously passing.
            @test isempty(messages("""
                databases:
                  dir:
                    dada2:
                      local: /no/such/dir/path
                  pr2:
                    levels: [Domain]
                """))

            # A NUL byte in a local: path cannot name a file: isfile throws on
            # one rather than answering false, and YAML admits NUL in a string.
            # _is_named_file must report it as an ordinary error, not throw.
            @test messages("databases:\n  pr2:\n    dada2:\n      local: \"a\\0b\"\n") ==
                ["pr2.dada2.local: file not found: a\0b"]

            # isfile throws IOError EACCES, not merely answering false, when a
            # parent directory cannot be read. Simulated without root by chmod-ing
            # a directory to remove read/execute permission; skipped only where
            # this runs as root, to whom no directory is ever unreadable.
            if ccall(:geteuid, Cint, ()) != 0
                locked = joinpath(tmp, "locked")
                mkpath(locked)
                target = joinpath(locked, "id_rsa")
                touch(target)
                chmod(locked, 0o000)
                try
                    @test messages("databases:\n  pr2:\n    dada2:\n      local: $target\n") ==
                        ["pr2.dada2.local: file not found: $target"]
                finally
                    chmod(locked, 0o755)
                end
            end
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    @testset "_validate_pipeline_cfg - valid" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "dada2"    => Dict(
                "filter_trim" => Dict("trunc_len" => [240, 160], "min_len" => 100, "max_ee" => [2, 2]),
                "taxonomy"    => Dict("database" => "pr2", "multithread" => 4),
            ),
            "vsearch"  => Dict("identity" => 0.75, "query_cov" => 0.8),
            "cdhit"    => Dict("identity" => 0.97),
            "swarm"    => Dict("differences" => 1, "identity" => 0.97),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test isempty(errors)
    end

    @testset "_validate_pipeline_cfg - trunc_len < min_len" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "dada2"    => Dict(
                "filter_trim" => Dict("trunc_len" => [80, 80], "min_len" => 100, "max_ee" => [2, 2]),
            ),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("trunc_len", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - identity out of range" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "vsearch"  => Dict("identity" => 1.5),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("identity", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - empty primer_pairs" begin
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => [], "min_length" => 200),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("primer_pairs", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - denovo_method whitelist" begin
        # Valid values pass.
        for v in Validation.DENOVO_METHODS
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "asv"      => Dict("denovo_method" => v),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test !any(e -> occursin("denovo_method", e.message), errors)
        end

        # An unrecognised method (the canonical scenario: capitalised typo) is rejected.
        cfg = Dict(
            "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
            "asv"      => Dict("denovo_method" => "Consensus"),
        )
        errors = Validation.ValidationError[]
        Validation._validate_pipeline_cfg(errors, cfg, "test")
        @test any(e -> occursin("denovo_method", e.message), errors)
    end

    @testset "_validate_pipeline_cfg - multithread accepts Bool and positive Integer" begin
        for v in (true, false, 1, 4)
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "dada2"    => Dict("taxonomy" => Dict("multithread" => v)),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test !any(e -> occursin("multithread", e.message), errors)
        end
    end

    @testset "_validate_pipeline_cfg - multithread rejects string and float" begin
        for v in ("4", 4.0, 0)
            cfg = Dict(
                "cutadapt" => Dict("primer_pairs" => ["EMP"], "min_length" => 200),
                "dada2"    => Dict("taxonomy" => Dict("multithread" => v)),
            )
            errors = Validation.ValidationError[]
            Validation._validate_pipeline_cfg(errors, cfg, "test")
            @test any(e -> occursin("multithread", e.message), errors)
        end
    end

    @testset "validate_environment - missing tools config" begin
        n = Validation.validate_environment(
            ProjectCtx[],
            "/nonexistent/databases.yml",
            "/nonexistent/tools.yml"
        )
        @test n > 0
    end

    @testset "validate_environment - empty tools config" begin
        mktempdir() do tmp
            tools_cfg = joinpath(tmp, "tools.yml")
            write(tools_cfg, "")
            db_cfg = joinpath(tmp, "databases.yml")
            write(db_cfg, "databases: {}")
            n = Validation.validate_environment(ProjectCtx[], db_cfg, tools_cfg)
            # Empty tools.yml is not a valid Dict; expect at least 1 error
            @test n > 0
        end
    end

end
