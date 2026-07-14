# Unit tests for the one-shot composition migration.
using Test
using YAML
include(joinpath(@__DIR__, "..", "..", "scripts", "migrate_composition.jl"))

@testset "MigrateComposition.convert" begin
    cfg = mktempdir()
    mkpath(joinpath(cfg, "compositions"))
    mkpath(joinpath(cfg, "filters"))

    write(joinpath(cfg, "compositions", "default.yml"), """
    name: "Default Composition"
    categories:
      - name: "Bacteria"
        colour: "#8e44ad"
        filter: "bacteria.pr2.yml"
      - name: "Eukaryota"
        colour: "#2980b9"
        filter: "protist.pr2.yml"
        funcdb_require: "18S"
      - name: "Contaminant"
        colour: "#c0392b"
    """)
    # Referenced by a set: a membership filter.
    write(joinpath(cfg, "filters", "bacteria.pr2.yml"), """
    filters:
      - { column: Domain, type: include, values: [Bacteria] }
    """)
    write(joinpath(cfg, "filters", "protist.pr2.yml"), """
    filters:
      - { column: Domain, type: include, values: [Eukaryota] }
    """)
    # Referenced by nothing: a saved table preset.
    write(joinpath(cfg, "filters", "min_pident.yml"), """
    filters:
      - { column: "Pident", type: min, value: 80 }
    """)

    result = MigrateComposition.convert(cfg)

    lib = YAML.load_file(result.library_path)
    # The membership filter is keyed by its stem, and the set references that name.
    @test haskey(lib["filters"], "bacteria.pr2")
    @test lib["sets"]["default"]["categories"][1]["filter"] == "bacteria.pr2"
    # The catch-all category survives without a filter key.
    @test !haskey(lib["sets"]["default"]["categories"][3], "filter")
    # The unreferenced filter moved to presets, and is not in the library.
    @test isfile(joinpath(cfg, "presets", "min_pident.yml"))
    @test !haskey(lib["filters"], "min_pident")
    # A backup of the old tree exists.
    @test isdir(result.backup_dir)

    ## Extra: category order is preserved (order is precedence: first match wins).
    cats = lib["sets"]["default"]["categories"]
    @test cats[1]["name"] == "Bacteria"
    @test cats[2]["name"] == "Eukaryota"
    @test cats[3]["name"] == "Contaminant"

    ## Extra: the second category's filter reference is also rewritten to its
    # bare stem, and its funcdb_require key survives the migration untouched.
    @test cats[2]["filter"] == "protist.pr2"
    @test haskey(lib["filters"], "protist.pr2")
    @test cats[2]["funcdb_require"] == "18S"
    @test !haskey(cats[3], "funcdb_require")
end

@testset "MigrateComposition keeps unreferenced taxonomic filters in the library" begin
    # config/filters/ is a LIBRARY of taxonomic definitions, and several shipped
    # ones (bacteria_archaea, environmental_protozoa, parasitic_protozoa,
    # plants_invertebrates) are cited by no set. Classifying on reference alone
    # would demote them to table presets, stripping them from the composition
    # builder and losing curated work. A membership filter declares the taxonomy
    # database it targets; a preset saved from the Tables view never does.
    cfg = mktempdir()
    mkpath(joinpath(cfg, "compositions"))
    mkpath(joinpath(cfg, "filters"))

    write(joinpath(cfg, "compositions", "default.yml"), """
    name: "Default Composition"
    categories:
      - name: "Bacteria"
        colour: "#8e44ad"
        filter: "bacteria.pr2.yml"
    """)
    write(joinpath(cfg, "filters", "bacteria.pr2.yml"), """
    databases: [pr2]
    filters:
      - { column: Domain, type: include, values: [Bacteria] }
    """)
    # A taxonomic filter that no set cites: it must still reach the library.
    write(joinpath(cfg, "filters", "environmental_protozoa.pr2.yml"), """
    databases: [pr2]
    filters:
      - { column: Subdivision, pattern: "Cercozoa|Gyrista", regex: true, action: keep }
    """)
    # A genuine saved table preset: no databases key, filters an analysis column.
    write(joinpath(cfg, "filters", "min_pident.yml"), """
    # Saved from table merged
    filters:
      - { column: "Pident", type: min, value: 80 }
    """)

    result = MigrateComposition.convert(cfg)
    lib = YAML.load_file(result.library_path)

    @test haskey(lib["filters"], "environmental_protozoa.pr2")
    @test !isfile(joinpath(cfg, "presets", "environmental_protozoa.pr2.yml"))
    # Only the true table preset moves out.
    @test result.presets_moved == ["min_pident.yml"]
    @test isfile(joinpath(cfg, "presets", "min_pident.yml"))
    @test !haskey(lib["filters"], "min_pident")
end
