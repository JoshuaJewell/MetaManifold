@testset "Databases" begin

    @testset "make_db_meta parses database config" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "databases.yml")
        write(cfg_path, """
databases:
  dir: ./databases
  pr2:
    levels: [Domain, Supergroup, Division, Class, Order, Family, Genus, Species]
    vsearch_format: pr2
    corrections:
      - source: Division
        target: Supergroup
        values:
          Rhizaria: Rhizaria
    dada2:
      uri: "https://example.com/pr2_dada2.fasta"
    vsearch:
      uri: "https://example.com/pr2_vsearch.fasta"
""")
        meta = Databases.make_db_meta(cfg_path, "pr2")
        @test meta.name == "pr2"
        @test meta.levels == ["Domain", "Supergroup", "Division", "Class",
                              "Order", "Family", "Genus", "Species"]
        @test meta.vsearch_format == "pr2"
        @test length(meta.corrections) == 1
        @test meta.corrections[1]["source"] == "Division"

        # noncounts includes taxonomy levels and their suffixed variants
        @test "Domain" in meta.noncounts
        @test "Domain_dada2" in meta.noncounts
        @test "Domain_vsearch" in meta.noncounts
        @test "Domain_boot" in meta.noncounts
        @test "SeqName" in meta.noncounts  # fixed noncount

        rm(dir; recursive=true)
    end

    @testset "make_db_meta errors on missing database" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "databases.yml")
        write(cfg_path, "databases:\n  dir: ./databases\n")
        @test_throws ErrorException Databases.make_db_meta(cfg_path, "nonexistent")
        rm(dir; recursive=true)
    end

    @testset "make_db_meta with no corrections" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "databases.yml")
        write(cfg_path, """
databases:
  dir: ./databases
  silva:
    levels: [Domain, Phylum, Class]
    vsearch_format: silva
    dada2:
      uri: "https://example.com/silva.fasta"
""")
        meta = Databases.make_db_meta(cfg_path, "silva")
        @test meta.name == "silva"
        @test meta.vsearch_format == "silva"
        @test isempty(meta.corrections)
        rm(dir; recursive=true)
    end

    @testset "ensure_databases with local paths" begin
        dir = mktempdir()
        db_dir = joinpath(dir, "databases")
        mkpath(db_dir)

        # Create fake local database files
        local_dada2 = joinpath(db_dir, "pr2_dada2.fasta")
        local_vsearch = joinpath(db_dir, "pr2_vsearch.fasta")
        write(local_dada2, ">seq1\nACGT\n")
        write(local_vsearch, ">seq1\nACGT\n")

        cfg_path = joinpath(dir, "databases.yml")
        write(cfg_path, """
databases:
  dir: $db_dir
  pr2:
    dada2:
      local: "$local_dada2"
    vsearch:
      local: "$local_vsearch"
""")

        resolved = Databases.ensure_databases(cfg_path)
        @test haskey(resolved, "pr2_dada2")
        @test haskey(resolved, "pr2_vsearch")
        @test resolved["pr2_dada2"] == local_dada2
        @test resolved["pr2_vsearch"] == local_vsearch

        rm(dir; recursive=true)
    end

    @testset "ensure_databases with missing config" begin
        dir = mktempdir()
        result = Databases.ensure_databases(joinpath(dir, "nonexistent.yml"))
        @test isempty(result)
        rm(dir; recursive=true)
    end

    @testset "ensure_databases skips null uri and local" begin
        dir = mktempdir()
        cfg_path = joinpath(dir, "databases.yml")
        write(cfg_path, """
databases:
  dir: ./databases
  pr2:
    dada2:
      uri: ~
      local: ~
""")
        resolved = Databases.ensure_databases(cfg_path)
        @test !haskey(resolved, "pr2_dada2")
        rm(dir; recursive=true)
    end

    ## Every format of one logical database must be drawn from the SAME upstream
    # release. The dual-classifier consensus
    # (FuncDBAnnotation._compute_consensus_rank) compares the DADA2 and VSEARCH
    # labels for string equality, so references from different releases score
    # genuine agreements as disagreements. The shipped defaults once pinned DADA2
    # to PR2 5.0.0 and VSEARCH to 5.1.0; 5.1.0 alone retaxonomised 7375 annotated
    # entries and switched species names from underscores to hyphens.
    @testset "database formats share one upstream release" begin
        # The release as the artefact itself declares it: PR2 names its assets
        # `pr2_version_<release>_SSU_<format>.fasta.gz`. The release tag is not
        # authoritative (tag `v5.1.0.0` carries assets named `5.1.0`).
        function _declared_release(uri::AbstractString)
            m = match(r"_version_([0-9]+(?:\.[0-9]+)*)_", basename(uri))
            isnothing(m) ? nothing : m.captures[1]
        end

        # Formats that name a reference artefact. `levels`, `corrections`, and
        # `vsearch_format` are metadata, not downloads.
        format_keys = ("dada2", "vsearch")

        for cfg_path in ("config/defaults/databases.yml", "config/ci/databases.yml")
            cfg = YAML.load_file(joinpath(@__DIR__, "..", "..", cfg_path))
            for (db_name, entry) in get(cfg, "databases", Dict())
                entry isa Dict || continue   # skips the scalar `dir:` key
                releases = Dict{String,String}()
                for fmt in format_keys
                    fmt_cfg = get(entry, fmt, nothing)
                    fmt_cfg isa Dict || continue
                    uri = get(fmt_cfg, "uri", nothing)
                    isnothing(uri) && continue
                    rel = _declared_release(string(uri))
                    isnothing(rel) && continue
                    releases[fmt] = rel
                end
                isempty(releases) && continue
                @test length(unique(values(releases))) == 1
            end
        end
    end

end
