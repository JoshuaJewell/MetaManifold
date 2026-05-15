## Copyright
# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

@testset "FuncDBAnnotation" begin

    # Helper: create a minimal FuncDB CSV mirroring the real schema.
    # Domain, taxonomy columns (supergroup to Species), Assignment_level,
    # Function (merged main+secondary), Detailed_function (merged), value columns.
    function _write_test_funcdb(path; rows=nothing)
        if isnothing(rows)
            rows = [
                # Domain, supergroup, division, class, order, family, Genus, Species,
                # Assignment_level,
                # Function, Detailed_function,
                # Associated_organism, Associated_material, Environment,
                # Potential_human_pathogen, Comment, Reference

                # Species-level entry: only goes in species map.
                ("Eukaryota", "Opisthokonta", "Ascomycota", "Saccharomycetes", "Saccharomycetales", "Saccharomycetaceae",
                 "Saccharomyces", "Saccharomyces_cerevisiae", "species",
                 "saprotroph", "fermentation saprotroph",
                 "", "grain", "industrial", "", "common brewer's yeast", "Ref1"),

                # Genus-level entry (no species): goes in genus map only.
                # Used for genus-fallback tests.
                ("Eukaryota", "Opisthokonta", "Ascomycota", "Eurotiomycetes", "Eurotiales", "Aspergillaceae",
                 "Aspergillus", "", "genus",
                 "saprotroph", "litter saprotroph",
                 "", "soil", "terrestrial", "", "", "Ref2"),

                # Species-level entry: only in species map (for DADA2 test).
                ("Eukaryota", "Opisthokonta", "Ascomycota", "Saccharomycetes", "Candida", "Debaryomycetaceae",
                 "Candida", "Candida_albicans", "species",
                 "symbiotroph", "animal parasite",
                 "animal", "", "animal material", "opportunistic", "", "Ref3"),

                # Family-level entry (no genus or species): goes in family map only.
                # Used for family-fallback tests.
                ("Eukaryota", "Alveolata", "Apicomplexa", "Conoidasida", "Eucoccidiorida", "Eimeriidae",
                 "", "", "family",
                 "symbiotroph", "animal parasite",
                 "animal", "", "animal material", "", "", "Ref4"),
            ]
        end

        df = DataFrame(
            Domain=getindex.(rows, 1),
            supergroup=getindex.(rows, 2), division=getindex.(rows, 3),
            class=getindex.(rows, 4), order=getindex.(rows, 5),
            family=getindex.(rows, 6), Genus=getindex.(rows, 7),
            Species=getindex.(rows, 8), Assignment_level=getindex.(rows, 9),
            Function=getindex.(rows, 10), Detailed_function=getindex.(rows, 11),
            Associated_organism=getindex.(rows, 12),
            Associated_material=getindex.(rows, 13),
            Environment=getindex.(rows, 14),
            Potential_human_pathogen=getindex.(rows, 15),
            Comment=getindex.(rows, 16), Reference=getindex.(rows, 17),
            Modified_by=fill("", length(rows)),
            Modified_date=fill("", length(rows)),
        )
        CSV.write(path, df)
    end

    @testset "Constants" begin
        @test length(FuncDBAnnotation.FUNCDB_VALUE_COLS) == 8
        @test length(FuncDBAnnotation.FUNCDB_OUTPUT_COLS) == 8
        @test FuncDBAnnotation.FUNCDB_OUTPUT_COLS[1] == "function"
        @test FuncDBAnnotation.FUNCDB_OUTPUT_COLS[end] == "reference"
        @test length(FuncDBAnnotation.RANK_HIERARCHY) == 7
        @test FuncDBAnnotation.RANK_HIERARCHY[1].rank == "species"
        @test FuncDBAnnotation.RANK_HIERARCHY[end].rank == "supergroup"
    end

    @testset "_normalize_key" begin
        nk = FuncDBAnnotation._normalize_key
        @test nk("  Hello World ") == "hello world"
        @test nk(missing) == ""
        @test nk(nothing) == ""
        @test nk("BLANK") == ""
        @test nk("blank") == ""
        @test nk("  Blank ") == ""
        @test nk("") == ""
        @test nk("Saccharomyces_cerevisiae") == "saccharomyces_cerevisiae"
    end

    @testset "load_funcdb" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            maps = load_funcdb(fpath)

            # Returns a Dict keyed by rank name
            @test maps isa Dict
            for r in FuncDBAnnotation.RANK_HIERARCHY
                @test haskey(maps, r.rank)
            end

            # Species-level entries: only in species map (assignment_level="species")
            @test  haskey(maps["species"], "saccharomyces_cerevisiae")
            @test  haskey(maps["species"], "candida_albicans")
            @test !haskey(maps["genus"],   "saccharomyces")  # species-level entry not extended to genus
            @test !haskey(maps["genus"],   "candida")

            # Genus-level entry: only in genus map (no species key because Species is blank)
            @test  haskey(maps["genus"],   "aspergillus")
            @test !haskey(maps["family"],  "aspergillaceae")  # genus-level entry not extended to family

            # Family-level entry: only in family map
            @test  haskey(maps["family"],  "eimeriidae")
            @test !haskey(maps["order"],   "eucoccidiorida")  # family-level entry not extended to order
            @test !haskey(maps["supergroup"], "alveolata")

            vals = maps["species"]["saccharomyces_cerevisiae"]
            @test vals.Function == "saprotroph"
            @test vals.Reference == "Ref1"
        end
    end

    @testset "load_funcdb duplicate species key warns, first wins" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            rows = [
                ("", "SG", "Div", "Cls", "Ord", "Fam", "DupGenus", "Dup_species", "species",
                 "phototroph", "D1", "", "", "", "", "C1", "R1"),
                ("", "SG", "Div", "Cls", "Ord", "Fam", "DupGenus", "Dup_species", "species",
                 "predator", "D2", "", "", "", "", "C2", "R2"),
            ]
            _write_test_funcdb(fpath; rows)

            maps = load_funcdb(fpath)
            @test maps["species"]["dup_species"].Function == "phototroph"
        end
    end

    @testset "load_funcdb missing file" begin
        @test_throws ErrorException load_funcdb("/nonexistent/path.csv")
    end

    @testset "load_funcdb Assignment_level caps rank maps" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            rows = [
                # genus-level assignment: only species + genus maps should be populated
                ("", "Opisthokonta", "Ascomycota", "Saccharomycetes", "Saccharomycetales", "Saccharomycetaceae",
                 "RestrictedGenus", "", "genus",
                 "saprotroph", "", "", "", "", "", "", "Ref"),
            ]
            _write_test_funcdb(fpath; rows)
            maps = load_funcdb(fpath)

            @test  haskey(maps["genus"], "restrictedgenus")
            @test !haskey(maps["family"],     "saccharomycetaceae")
            @test !haskey(maps["order"],      "saccharomycetales")
            @test !haskey(maps["class"],      "saccharomycetes")
            @test !haskey(maps["division"],   "ascomycota")
            @test !haskey(maps["supergroup"], "opisthokonta")
        end
    end

    @testset "annotate_table VSEARCH - Assignment_level blocks coarser match" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            rows = [
                # genus-level: family match for a different genus should NOT hit this entry
                ("", "Opisthokonta", "Ascomycota", "Saccharomycetes", "Saccharomycetales", "Saccharomycetaceae",
                 "RestrictedGenus", "", "genus",
                 "saprotroph", "", "", "", "", "", "", "Ref"),
            ]
            _write_test_funcdb(fpath; rows)

            source = DataFrame(
                SeqName    = ["seq1"],
                Species    = ["Unknown_sp."],
                Genus      = ["DifferentGenus"],
                Family     = ["Saccharomycetaceae"],   # matches family, but entry is genus-capped
                Order      = ["Saccharomycetales"],
                Class      = ["Saccharomycetes"],
                Division   = ["Ascomycota"],
                Supergroup = ["Opisthokonta"],
            )
            result = annotate_table(source, "VSEARCH", fpath)

            @test result[1, "match_rank"] == "unmatched"
        end
    end

    @testset "annotate_table VSEARCH - species match" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName  = ["seq1"],
                Species  = ["Saccharomyces_cerevisiae"],
                Genus    = ["Saccharomyces"],
                Family   = ["Saccharomycetaceae"],
                Order    = ["Saccharomycetales"],
                Class    = ["Saccharomycetes"],
                Division = ["Ascomycota"],
                Supergroup = ["Opisthokonta"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test result[1, "function"] == "saprotroph"
            @test result[1, "match_rank"] == "species"
        end
    end

    @testset "annotate_table VSEARCH - genus fallback" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            # Species not in FuncDB; genus "Aspergillus" has a genus-level entry.
            source = DataFrame(
                SeqName  = ["seq1"],
                Species  = ["Aspergillus_unknown"],
                Genus    = ["Aspergillus"],
                Family   = ["Aspergillaceae"],
                Order    = ["Eurotiales"],
                Class    = ["Eurotiomycetes"],
                Division = ["Ascomycota"],
                Supergroup = ["Opisthokonta"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test result[1, "function"] == "saprotroph"
            @test result[1, "match_rank"] == "genus"
        end
    end

    @testset "annotate_table VSEARCH - family fallback" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            # Species and genus unknown; family "Eimeriidae" has a family-level entry.
            source = DataFrame(
                SeqName  = ["seq1"],
                Species  = ["Eimeria_unknown"],
                Genus    = ["UnknownGenus"],
                Family   = ["Eimeriidae"],
                Order    = ["Eucoccidiorida"],
                Class    = ["Conoidasida"],
                Division = ["Apicomplexa"],
                Supergroup = ["Alveolata"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test result[1, "match_rank"] == "family"
            @test result[1, "function"] == "symbiotroph"
        end
    end

    @testset "annotate_table VSEARCH - unmatched" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName  = ["seq1"],
                Species  = ["NoMatch_sp."],
                Genus    = ["NoMatchGenus"],
                Family   = ["NoMatchFamily"],
                Order    = ["NoMatchOrder"],
                Class    = ["NoMatchClass"],
                Division = ["NoMatchDivision"],
                Supergroup = ["NoMatchSupergroup"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test result[1, "match_rank"] == "unmatched"
            @test result[1, "function"] == ""
        end
    end

    @testset "annotate_table VSEARCH - drops DADA2 columns" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName      = ["seq1"],
                Species      = ["Saccharomyces_cerevisiae"],
                Genus        = ["Saccharomyces"],
                Species_dada2 = ["Something_dada2"],
                Genus_dada2  = ["SomethingGenus"],
                Domain_boot  = [95],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test "Species" in names(result)
            @test "Genus" in names(result)
            @test !("Species_dada2" in names(result))
            @test !("Genus_dada2" in names(result))
            @test !("Domain_boot" in names(result))
        end
    end

    @testset "annotate_table DADA2 - drops VSEARCH columns" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName       = ["seq1"],
                Species_dada2 = ["Candida_albicans"],
                Genus_dada2   = ["Candida"],
                Pident        = [98.5],
                Species       = ["SomeVsearchSpecies"],
                Genus         = ["SomeVsearchGenus"],
            )

            result = annotate_table(source, "DADA2", fpath)

            @test "Species_dada2" in names(result)
            @test "Genus_dada2" in names(result)
            @test !("Pident" in names(result))
            @test !("Species" in names(result))
            @test !("Genus" in names(result))
            @test result[1, "function"] == "symbiotroph"
            @test result[1, "match_rank"] == "species"
        end
    end

    @testset "annotate_table VSEARCH - max_rank genus ignores and drops species" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName     = ["seq1"],
                Species     = ["Aspergillus_unknown"],
                Genus       = ["Aspergillus"],
                Family      = ["Aspergillaceae"],
                Order       = ["Eurotiales"],
                Class       = ["Eurotiomycetes"],
                Division    = ["Ascomycota"],
                Supergroup  = ["Opisthokonta"],
            )

            result = annotate_table(source, "VSEARCH", fpath; max_rank="genus")

            @test !("Species" in names(result))
            @test "Genus" in names(result)
            @test result[1, "match_rank"] == "genus"
        end
    end

    @testset "annotate_table DADA2 - max_rank genus drops species and species_boot" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName        = ["seq1"],
                Species_dada2  = ["Aspergillus_unknown"],
                Genus_dada2    = ["Aspergillus"],
                Family_dada2   = ["Aspergillaceae"],
                Order_dada2    = ["Eurotiales"],
                Class_dada2    = ["Eurotiomycetes"],
                Division_dada2 = ["Ascomycota"],
                Supergroup_dada2 = ["Opisthokonta"],
                Species_boot   = [100],
                Genus_boot     = [99],
            )

            result = annotate_table(source, "DADA2", fpath; max_rank="genus")

            @test !("Species_dada2" in names(result))
            @test !("Species_boot" in names(result))
            @test "Genus_dada2" in names(result)
            @test "Genus_boot" in names(result)
            @test result[1, "match_rank"] == "genus"
        end
    end

    @testset "annotate_table invalid taxonomy_source" begin
        df = DataFrame(Species=["a"], Genus=["b"])
        @test_throws ErrorException annotate_table(df, "INVALID", "/fake.csv")
    end

    @testset "annotate_table all output columns present" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(Species=["x"], Genus=["y"])
            result = annotate_table(source, "VSEARCH", fpath)

            for col in FuncDBAnnotation.FUNCDB_OUTPUT_COLS
                @test col in names(result)
            end
            @test "match_rank" in names(result)
            @test "consensus_rank" in names(result)
            @test "consensus_score" in names(result)
            @test "Contamination" in names(result)
            @test "BLAST Assignment" in names(result)
            @test all(result.Contamination .== "unassigned")
            @test all(result[!, "BLAST Assignment"] .== "")
            # Removed columns from old schema
            @test !("funcdb_taxonomy_source" in names(result))
            @test !("funcdb_matched_genus" in names(result))
            @test !("funcdb_matched_species" in names(result))
        end
    end

    @testset "annotate_table - total columns from per-sample counts" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                "SeqName"  => ["seq1", "seq2"],
                "Species"  => ["Saccharomyces_cerevisiae", "NoMatch_sp."],
                "Genus"    => ["Saccharomyces", "NoMatchGenus"],
                "V4-C-01"  => [10, 0],
                "V4-C-02"  => [5,  3],
                "V4-L-01"  => [0,  7],
                "V4-L-02"  => [2,  1],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test "total_C" in names(result)
            @test "total_L" in names(result)
            @test "total"   in names(result)
            @test result[1, "total_C"] == 15
            @test result[1, "total_L"] == 2
            @test result[1, "total"]   == 17
            @test result[2, "total_C"] == 3
            @test result[2, "total_L"] == 8
            @test result[2, "total"]   == 11
        end
    end

    @testset "annotate_table - no sample columns -> no total columns" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(SeqName=["seq1"], Species=["x"], Genus=["y"])
            result = annotate_table(source, "VSEARCH", fpath)

            @test !("total" in names(result))
        end
    end

    @testset "annotate_table - consensus_rank and consensus_score" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            # Source with both VSEARCH and DADA2 columns + Pident + 2 bootstrap cols
            source = DataFrame(
                SeqName        = ["seq1", "seq2", "seq3"],
                Pident         = [98.0,    85.0,   70.0],
                Species        = ["Saccharomyces_cerevisiae", "Aspergillus_niger", "Unknown"],
                Genus          = ["Saccharomyces",            "Aspergillus",       "Unknown"],
                Family         = ["Saccharomycetaceae",       "Aspergillaceae",    "UnknownFam"],
                Order          = ["Saccharomycetales",        "Eurotiales",        "UnknownOrd"],
                Class          = ["Saccharomycetes",          "Eurotiomycetes",    "UnknownCls"],
                Division       = ["Ascomycota",               "Ascomycota",        "UnknownDiv"],
                Supergroup     = ["Opisthokonta",             "Opisthokonta",      "UnknownSG"],
                Species_dada2  = ["Saccharomyces_cerevisiae", "Aspergillus_OTHER", ""],
                Genus_dada2    = ["Saccharomyces",            "Aspergillus",       ""],
                Family_dada2   = ["Saccharomycetaceae",       "Aspergillaceae",    ""],
                Order_dada2    = ["Saccharomycetales",        "Eurotiales",        ""],
                Class_dada2    = ["Saccharomycetes",          "Eurotiomycetes",    ""],
                Division_dada2 = ["Ascomycota",               "Ascomycota",        ""],
                Supergroup_dada2 = ["Opisthokonta",           "Opisthokonta",      ""],
                Species_boot   = [100,     60,     0],
                Genus_boot     = [100,     90,     0],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test "consensus_rank"  in names(result)
            @test "consensus_score" in names(result)

            # 2 boot cols: Species_boot and Genus_boot

            # seq1: consensus=species (idx 1), both boots contribute.
            #   mean_boot = (100 + 100) / 2 = 100
            #   score = (100/100) * (98/100) = 0.98
            @test result[1, "consensus_rank"] == "species"
            @test result[1, "consensus_score"] ≈ 0.98

            # seq2: consensus=genus (idx 2), Species_boot finer -> 0.
            #   mean_boot = (0 + 90) / 2 = 45
            #   score = (45/100) * (85/100) = 0.3825
            @test result[2, "consensus_rank"] == "genus"
            @test result[2, "consensus_score"] ≈ 0.3825

            # seq3: no consensus -> score is missing
            @test result[3, "consensus_rank"] == ""
            @test ismissing(result[3, "consensus_score"])
        end
    end

    @testset "annotate_table - consensus_score with only Pident (no bootstrap)" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            source = DataFrame(
                SeqName        = ["seq1"],
                Pident         = [92.0],
                Species        = ["Saccharomyces_cerevisiae"],
                Genus          = ["Saccharomyces"],
                Species_dada2  = ["Saccharomyces_cerevisiae"],
                Genus_dada2    = ["Saccharomyces"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            # No boot cols -> mean_boot defaults to 100, score = (100/100) * (92/100) = 0.92
            @test result[1, "consensus_rank"] == "species"
            @test result[1, "consensus_score"] ≈ 0.92
        end
    end

    @testset "annotate_table - consensus_rank without DADA2 columns" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            # Only VSEARCH columns - consensus should be empty, score missing
            source = DataFrame(
                SeqName    = ["seq1"],
                Pident     = [99.0],
                Species    = ["Saccharomyces_cerevisiae"],
                Genus      = ["Saccharomyces"],
            )

            result = annotate_table(source, "VSEARCH", fpath)

            @test "consensus_rank"  in names(result)
            @test "consensus_score" in names(result)
            @test result[1, "consensus_rank"] == ""
            @test ismissing(result[1, "consensus_score"])
        end
    end

    @testset "append_funcdb_entry" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            entry = Dict(
                "Domain" => "Eukaryota",
                "supergroup" => "Opisthokonta", "division" => "Ascomycota",
                "class" => "Saccharomycetes", "order" => "Saccharomycetales",
                "family" => "Saccharomycetaceae",
                "Genus" => "Saccharomyces", "Species" => "Saccharomyces_paradoxus",
                "Assignment_level" => "species",
                "Function" => "saprotroph",
            )
            row = append_funcdb_entry(fpath, entry; modified_by="test_user")
            @test row.Species == "Saccharomyces_paradoxus"
            @test row.Modified_by == "test_user"
            @test row.Modified_date == string(Dates.today())

            # Verify it's loadable and the new entry is in the species map
            maps = load_funcdb(fpath)
            @test haskey(maps["species"], "saccharomyces_paradoxus")
            @test maps["species"]["saccharomyces_paradoxus"].Function == "saprotroph"
        end
    end

    @testset "append_funcdb_entry validation" begin
        mktempdir() do dir
            fpath = joinpath(dir, "FuncDB_species.csv")
            _write_test_funcdb(fpath)

            # Missing Function
            @test_throws ErrorException append_funcdb_entry(fpath, Dict("Genus" => "Foo"))

            # No taxonomy key at all
            @test_throws ErrorException append_funcdb_entry(fpath, Dict("Function" => "saprotroph"))
        end
    end

end
