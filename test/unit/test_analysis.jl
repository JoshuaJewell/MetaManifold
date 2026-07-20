@testset "Analysis chart builders" begin

    @testset "_palette_hex" begin
        c3 = Analysis._palette_hex(3)
        @test length(c3) == 3
        @test all(s -> startswith(s, "#") && length(s) == 7, c3)

        c10 = Analysis._palette_hex(10)
        @test length(c10) == 10
        @test allunique(c10)

        c7 = Analysis._palette_hex(7)
        @test c7[1] == "#E69F00"
    end

    @testset "alpha_chart" begin
        samples = ["s1", "s2", "s3"]
        r = [10, 20, 30]
        h = [1.0, 2.0, 2.5]
        s = [0.7, 0.8, 0.9]

        fig = Analysis.alpha_chart(samples, r, h, s)
        @test haskey(fig, "data") && haskey(fig, "layout")
        @test length(fig["data"]) == 3  # one trace per metric
        # 3-panel layout keys
        @test haskey(fig["layout"], "yaxis2") && haskey(fig["layout"], "yaxis3")

        fig_empty = Analysis.alpha_chart(String[], Int[], Float64[], Float64[])
        @test haskey(fig_empty, "data")
    end

    @testset "taxa_bar_chart" begin
        labels = ["Eukaryota", "Bacteria"]
        samples = ["s1", "s2"]
        counts = [100.0 30.0; 50.0 20.0]  # 2 taxa x 2 samples

        fig = Analysis.taxa_bar_chart(labels, samples, counts)
        @test haskey(fig, "data") && haskey(fig, "layout")
        @test fig["layout"]["barmode"] == "stack"
        @test length(fig["data"]) == 2

        # Absolute mode
        fig_abs = Analysis.taxa_bar_chart(labels, samples, counts; relative=false)
        @test !haskey(fig_abs["layout"]["yaxis"], "range")

        # Relative mode has range [0, 1]
        fig_rel = Analysis.taxa_bar_chart(labels, samples, counts; relative=true)
        @test fig_rel["layout"]["yaxis"]["range"] == [0, 1]
    end

    @testset "taxa_bar_chart top_n collapsing" begin
        labels = ["T$i" for i in 1:20]
        samples = ["s1"]
        counts = Float64[i for i in 1:20] |> c -> reshape(c, 20, 1)

        fig = Analysis.taxa_bar_chart(labels, samples, counts; top_n=5)
        trace_names = [t["name"] for t in fig["data"]]
        @test "Other" in trace_names
        @test length(trace_names) == 6  # top 5 + Other
    end

    @testset "pipeline_stats_chart" begin
        sdf = DataFrame(sample=["s1", "s2"],
                        input=[1000, 800], filtered=[900, 700], nochim=[850, 650])
        fig = Analysis.pipeline_stats_chart(sdf)
        @test !isnothing(fig)
        @test haskey(fig, "data") && haskey(fig, "layout")
        @test fig["layout"]["barmode"] == "group"
        @test length(fig["data"]) == 2  # one bar series per sample

        @test isnothing(Analysis.pipeline_stats_chart(DataFrame(sample=String[])))
    end

    @testset "nmds_chart" begin
        coords = [0.1 0.2; -0.3 0.4; 0.5 -0.1]
        labels = ["s1", "s2", "s3"]

        fig = Analysis.nmds_chart(coords, labels;
            colour_by=["A", "B", "A"], stress=0.12)
        @test haskey(fig, "data") && haskey(fig, "layout")
        @test length(fig["data"]) == 2  # 2 colour groups: A, B
        # Stress annotation present
        @test !isempty(fig["layout"]["annotations"])
        @test occursin("stress", fig["layout"]["annotations"][1]["text"])

        fig2 = Analysis.nmds_chart(coords, labels)
        @test length(fig2["data"]) == 1

        fig3 = Analysis.nmds_chart(zeros(0, 2), String[])
        @test haskey(fig3, "data")
    end

    @testset "alpha_boxplot" begin
        groups = [
            ("GroupA", [10, 20], [1.0, 2.0], [0.7, 0.8]),
            ("GroupB", [5, 15],  [0.8, 1.8], [0.6, 0.75]),
        ]

        fig = Analysis.alpha_boxplot(groups)
        @test haskey(fig, "data") && haskey(fig, "layout")
        @test length(fig["data"]) == 6  # 3 panels * 2 groups
        # Only first panel traces show legend
        legend_traces = [t for t in fig["data"] if get(t, "showlegend", false)]
        @test length(legend_traces) == 2

        # The overall-significance label must anchor to its panel's axis domain,
        # not to paper: a paper-referenced annotation cannot survive the
        # frontend's per-metric axis renumbering and spawns phantom axes.
        annotated = Analysis.alpha_boxplot(groups; annotate_significance=true)
        sig_anns = get(annotated["layout"], "annotations", Any[])
        @test !isempty(sig_anns)
        @test all(a -> get(a, "xref", "") != "paper" && get(a, "yref", "") != "paper",
                  sig_anns)
        @test all(a -> endswith(String(get(a, "yref", "")), " domain"), sig_anns)
    end

    @testset "bar_chart modes and colour_for" begin
        fig = Analysis.bar_chart(["A", "B"], ["s1", "s2"],
            Float64[1 2; 3 4]; mode="group", relative=false,
            colour_for = l -> l == "A" ? "#111111" : "#222222")
        @test fig["layout"]["barmode"] == "group"
        # Traces are ordered by total descending: B(7) first, A(3) second.
        # Find the trace named "A" and check its colour.
        trace_a = first(filter(t -> t["name"] == "A", fig["data"]))
        @test trace_a["marker"]["color"] == "#111111"
        # Grouped absolute mode must not fix the y-axis range to [0, 1].
        @test !haskey(fig["layout"]["yaxis"], "range")

        # Stacked relative mode keeps the [0, 1] range.
        fig2 = Analysis.bar_chart(["A", "B"], ["s1", "s2"],
            Float64[1 2; 3 4]; mode="stacked", relative=true)
        @test fig2["layout"]["barmode"] == "stack"
        @test fig2["layout"]["yaxis"]["range"] == [0, 1]
    end

    @testset "pool_columns" begin
        counts = [10.0 20.0 30.0 40.0;
                   5.0 10.0 15.0 20.0]
        names = ["A_s1", "A_s2", "B_s1", "B_s2"]

        # Pool by prefix
        pn, pc = Analysis.pool_columns(names, counts, ["A", "B"])
        @test pn == ["A", "B"]
        @test pc[:, 1] == [30.0, 15.0]   # A_s1 + A_s2
        @test pc[:, 2] == [70.0, 35.0]   # B_s1 + B_s2

        # Pool with unmatched -> Other
        pn2, pc2 = Analysis.pool_columns(names, counts, ["A"])
        @test pn2 == ["A", "Other"]
        @test pc2[:, 1] == [30.0, 15.0]
        @test pc2[:, 2] == [70.0, 35.0]

        # Empty groups -> pool all
        pn3, pc3 = Analysis.pool_columns(names, counts, String[])
        @test pn3 == ["Total"]
        @test pc3[:, 1] == [100.0, 50.0]

        # Custom fallback label
        pn4, _ = Analysis.pool_columns(names, counts, String[]; fallback_label="MyRun")
        @test pn4 == ["MyRun"]
    end

end
