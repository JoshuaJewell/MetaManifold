@testset "ProjectSetup" begin

    @testset "new_project discovers leaf runs" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))

        # Create default configs
        write(joinpath(config_dir, "defaults", "pipeline.yml"), "cutadapt:\n  cores: 0\n")
        write(joinpath(config_dir, "defaults", "databases.yml"), "databases:\n  dir: ./databases\n")
        write(joinpath(config_dir, "defaults", "tools.yml"), "cutadapt: cutadapt\n")
        write(joinpath(config_dir, "defaults", "primers.yml"), "Forward: {}\nReverse: {}\nPairs: []\n")
        write(joinpath(config_dir, "defaults", "composition.yml"), "filters: {}\nsets: {}\n")

        # Create data with two runs
        run_a = joinpath(dir, "data", "MyStudy", "run_A")
        run_b = joinpath(dir, "data", "MyStudy", "run_B")
        mkpath(run_a)
        mkpath(run_b)
        touch(joinpath(run_a, "sample1_R1.fastq.gz"))
        touch(joinpath(run_a, "sample1_R2.fastq.gz"))
        touch(joinpath(run_b, "sample2_R1.fastq.gz"))
        touch(joinpath(run_b, "sample2_R2.fastq.gz"))

        projects_dir = joinpath(dir, "projects")

        projects = new_project("MyStudy";
            data_dir=joinpath(dir, "data"),
            projects_dir=projects_dir,
            config_dir=config_dir)

        @test length(projects) == 2
        @test all(p -> isdir(p.dir), projects)

        # pipeline.yml stubs created at each level
        @test isfile(joinpath(dir, "data", "MyStudy", "pipeline.yml"))
        @test isfile(joinpath(run_a, "pipeline.yml"))
        @test isfile(joinpath(run_b, "pipeline.yml"))

        # Standalone configs copied from defaults
        @test isfile(joinpath(config_dir, "databases.yml"))
        @test isfile(joinpath(config_dir, "tools.yml"))
        @test isfile(joinpath(config_dir, "primers.yml"))
        # The composition library must reproduce from a clean checkout, or a
        # fresh install would start with no category sets at all.
        @test isfile(joinpath(config_dir, "composition.yml"))

        rm(dir; recursive=true)
    end

    @testset "new_project flat study (FASTQs at root)" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))
        write(joinpath(config_dir, "defaults", "pipeline.yml"), "cutadapt:\n  cores: 0\n")
        write(joinpath(config_dir, "defaults", "databases.yml"), "databases:\n  dir: ./databases\n")
        write(joinpath(config_dir, "defaults", "tools.yml"), "cutadapt: cutadapt\n")
        write(joinpath(config_dir, "defaults", "primers.yml"), "Forward: {}\nReverse: {}\nPairs: []\n")
        write(joinpath(config_dir, "defaults", "composition.yml"), "filters: {}\nsets: {}\n")

        study = joinpath(dir, "data", "FlatStudy")
        mkpath(study)
        touch(joinpath(study, "sample_R1.fastq.gz"))
        touch(joinpath(study, "sample_R2.fastq.gz"))

        projects = new_project("FlatStudy";
            data_dir=joinpath(dir, "data"),
            projects_dir=joinpath(dir, "projects"),
            config_dir=config_dir)

        @test length(projects) == 1
        @test projects[1].data_dir == study

        rm(dir; recursive=true)
    end

    @testset "new_project errors on missing data dir" begin
        dir = mktempdir()
        @test_throws ErrorException new_project("NonExistent";
            data_dir=joinpath(dir, "data"),
            projects_dir=joinpath(dir, "projects"),
            config_dir=joinpath(dir, "config"))
        rm(dir; recursive=true)
    end

    @testset "new_project errors on no FASTQs" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))
        write(joinpath(config_dir, "defaults", "pipeline.yml"), "cutadapt:\n  cores: 0\n")
        write(joinpath(config_dir, "defaults", "databases.yml"), "databases:\n  dir: ./databases\n")
        write(joinpath(config_dir, "defaults", "tools.yml"), "cutadapt: cutadapt\n")
        write(joinpath(config_dir, "defaults", "primers.yml"), "Forward: {}\nReverse: {}\nPairs: []\n")
        write(joinpath(config_dir, "defaults", "composition.yml"), "filters: {}\nsets: {}\n")

        mkpath(joinpath(dir, "data", "EmptyStudy"))

        @test_throws ErrorException new_project("EmptyStudy";
            data_dir=joinpath(dir, "data"),
            projects_dir=joinpath(dir, "projects"),
            config_dir=config_dir)

        rm(dir; recursive=true)
    end

    @testset "new_project does not overwrite existing files" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))
        write(joinpath(config_dir, "defaults", "pipeline.yml"), "cutadapt:\n  cores: 0\n")
        write(joinpath(config_dir, "defaults", "databases.yml"), "databases:\n  dir: ./databases\n")
        write(joinpath(config_dir, "defaults", "tools.yml"), "cutadapt: cutadapt\n")
        write(joinpath(config_dir, "defaults", "primers.yml"), "Forward: {}\nReverse: {}\nPairs: []\n")
        write(joinpath(config_dir, "defaults", "composition.yml"), "filters: {}\nsets: {}\n")

        run_dir = joinpath(dir, "data", "Study", "run")
        mkpath(run_dir)
        touch(joinpath(run_dir, "s_R1.fastq.gz"))

        # Write a custom pipeline.yml before new_project
        custom_content = "cutadapt:\n  min_length: 999\n"
        write(joinpath(run_dir, "pipeline.yml"), custom_content)

        new_project("Study";
            data_dir=joinpath(dir, "data"),
            projects_dir=joinpath(dir, "projects"),
            config_dir=config_dir)

        # Custom file should be preserved
        @test read(joinpath(run_dir, "pipeline.yml"), String) == custom_content

        rm(dir; recursive=true)
    end

    @testset "new_project with grouped runs" begin
        dir = mktempdir()
        config_dir = joinpath(dir, "config")
        mkpath(joinpath(config_dir, "defaults"))
        write(joinpath(config_dir, "defaults", "pipeline.yml"), "cutadapt:\n  cores: 0\n")
        write(joinpath(config_dir, "defaults", "databases.yml"), "databases:\n  dir: ./databases\n")
        write(joinpath(config_dir, "defaults", "tools.yml"), "cutadapt: cutadapt\n")
        write(joinpath(config_dir, "defaults", "primers.yml"), "Forward: {}\nReverse: {}\nPairs: []\n")
        write(joinpath(config_dir, "defaults", "composition.yml"), "filters: {}\nsets: {}\n")

        # study/group_A/run1, study/group_B/run2
        for (group, run) in [("group_A", "run1"), ("group_B", "run2")]
            d = joinpath(dir, "data", "Grouped", group, run)
            mkpath(d)
            touch(joinpath(d, "s_R1.fastq.gz"))
        end

        projects = new_project("Grouped";
            data_dir=joinpath(dir, "data"),
            projects_dir=joinpath(dir, "projects"),
            config_dir=config_dir)

        @test length(projects) == 2
        # Group-level pipeline.yml should exist
        @test isfile(joinpath(dir, "data", "Grouped", "group_A", "pipeline.yml"))
        @test isfile(joinpath(dir, "data", "Grouped", "group_B", "pipeline.yml"))

        rm(dir; recursive=true)
    end

end
