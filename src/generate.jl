"""
    generate(pkg::AbstractString, t::Template) -> Nothing
    generate(t::Template, pkg::AbstractString) -> Nothing

Generate a package named `pkg` from `t`. If `git` is `false`, no Git repository is created.
"""
function generate(
    pkg::AbstractString,
    t::Template;
    git::Bool=true,
    gitconfig::Union{GitConfig, Nothing}=nothing,
)
    pkg = splitjl(pkg)
    pkg_dir = joinpath(t.dir, pkg)
    ispath(pkg_dir) && throw(ArgumentError("$pkg_dir already exists"))

    try
        # Create the directory with some boilerplate inside.
        Pkg.generate(pkg_dir)

        # Replace the UUID with something that's compatible with METADATA.
        project = joinpath(pkg_dir, "Project.toml")
        uuid = string(Pkg.METADATA_compatible_uuid(pkg))
        write(project, replace(read(project, String), r"uuid = .*" => "uuid = \"$uuid\""))

        if git
            # Initialize the repo.
            repo = LibGit2.init(pkg_dir)
            @info "Initialized Git repo at $pkg_dir"

            if gitconfig !== nothing
                # Configure the repo.
                repoconfig = GitConfig(repo)
                for c in LibGit2.GitConfigIter(gitconfig)
                    LibGit2.set!(repoconfig, unsafe_string(c.name), unsafe_string(c.value))
                end
            end

            # Commit and set the remote.
            LibGit2.commit(repo, "Initial commit")
            rmt = if t.ssh
                "git@$(t.host):$(t.user)/$pkg.jl.git"
            else
                "https://$(t.host)/$(t.user)/$pkg.jl"
            end
            # We need to set the remote in a strange way, see #8.
            close(LibGit2.GitRemote(repo, "origin", rmt))
            @info "Set remote origin to $rmt"

            # Create the gh-pages branch if necessary.
            if haskey(t.plugins, GitHubPages)
                LibGit2.branch!(repo, "gh-pages")
                LibGit2.commit(repo, "Initial commit")
                @info "Created empty gh-pages branch"
                LibGit2.branch!(repo, "master")
            end
        end

        # Generate the files.
        files = vcat(
            "src/", "Project.toml",  # Created by Pkg.generate.
            gen_tests(pkg_dir, t),
            gen_require(pkg_dir, t),
            gen_readme(pkg_dir, t),
            gen_license(pkg_dir, t),
            vcat(map(p -> gen_plugin(p, t, pkg), values(t.plugins))...),
        )

        if git
            append!(files, gen_gitignore(pkg_dir, t))
            LibGit2.add!(repo, files...)
            LibGit2.commit(repo, "Files generated by PkgTemplates")
            @info "Committed $(length(files)) files/directories: $(join(files, ", "))"


            if length(collect(LibGit2.GitBranchIter(repo))) > 1
                @info "Remember to push all created branches to your remote: git push --all"
            end
        end

        # Add the new package to the current environment.
        Pkg.develop(PackageSpec(path=pkg_dir))

        @info "New package is at $pkg_dir"
    catch e
        rm(pkg_dir; recursive=true)
        rethrow(e)
    end
end

function generate(
    t::Template,
    pkg::AbstractString;
    git::Bool=true,
    gitconfig::Union{GitConfig, Nothing}=nothing,
)
    generate(pkg, t; git=git, gitconfig=gitconfig)
end

"""
    generate_interactive(pkg::AbstractString; fast::Bool=false, git::Bool=true) -> Template

Interactively create a template, and then generate a package with it. Arguments and
keywords are used in the same way as in [`generate`](@ref) and
[`interactive_template`](@ref).
"""
function generate_interactive(
    pkg::AbstractString;
    fast::Bool=false,
    git::Bool=true,
    gitconfig::Union{GitConfig, Nothing}=nothing,
)
    t = interactive_template(; git=git, fast=fast)
    generate(pkg, t; git=git, gitconfig=gitconfig)
    return t
end

"""
    gen_tests(pkg_dir::AbstractString, t::Template) -> Vector{String}

Create the test entrypoint in `pkg_dir`.

# Arguments
* `pkg_dir::AbstractString`: The package directory in which the files will be generated
* `t::Template`: The template whose tests we are generating.

Returns an array of generated file/directory names.
"""
function gen_tests(pkg_dir::AbstractString, t::Template)
    # TODO: Silence Pkg for this section? Adding and removing Test creates a lot of noise.
    proj = Base.current_project()
    try
        Pkg.activate(pkg_dir)
        Pkg.add("Test")

        # Move the Test dependency into the [extras] section.
        toml = read(joinpath(pkg_dir, "Project.toml"), String)
        lines = split(toml, "\n")
        idx = findfirst(l -> startswith(l, "Test = "), lines)
        testdep = lines[idx]
        deleteat!(lines, idx)
        toml = join(lines, "\n") * """
        [extras]
        $testdep

        [targets]
        test = ["Test"]
        """
        gen_file(joinpath(pkg_dir, "Project.toml"), toml)
        Pkg.update()  # Regenerate Manifest.toml (this cleans up Project.toml too).
    finally
        proj === nothing ? Pkg.activate() : Pkg.activate(proj)
    end

    pkg = basename(pkg_dir)
    text = """
        using $pkg
        using Test

        @testset "$pkg.jl" begin
            # Write your own tests here.
        end
        """

    gen_file(joinpath(pkg_dir, "test", "runtests.jl"), text)
    return ["test/"]
end

"""
    gen_require(pkg_dir::AbstractString, t::Template) -> Vector{String}

Create the `REQUIRE` file in `pkg_dir`.

# Arguments
* `pkg_dir::AbstractString`: The directory in which the files will be generated.
* `t::Template`: The template whose REQUIRE we are generating.

Returns an array of generated file/directory names.
"""
function gen_require(pkg_dir::AbstractString, t::Template)
    text = "julia $(version_floor(t.julia_version))\n"
    gen_file(joinpath(pkg_dir, "REQUIRE"), text)
    return ["REQUIRE"]
end

"""
    gen_readme(pkg_dir::AbstractString, t::Template) -> Vector{String}

Create a README in `pkg_dir` with badges for each enabled plugin.

# Arguments
* `pkg_dir::AbstractString`: The directory in which the files will be generated.
* `t::Template`: The template whose README we are generating.

Returns an array of generated file/directory names.
"""
function gen_readme(pkg_dir::AbstractString, t::Template)
    pkg = basename(pkg_dir)
    text = "# $pkg\n"
    done = []
    # Generate the ordered badges first, then add any remaining ones to the right.
    for plugin_type in BADGE_ORDER
        if haskey(t.plugins, plugin_type)
            text *= "\n"
            text *= join(
                badges(t.plugins[plugin_type], t.user, pkg),
                "\n",
            )
            push!(done, plugin_type)
        end
    end
    for plugin_type in setdiff(keys(t.plugins), done)
        text *= "\n"
        text *= join(
            badges(t.plugins[plugin_type], t.user, pkg),
            "\n",
        )
    end

    gen_file(joinpath(pkg_dir, "README.md"), text)
    return ["README.md"]
end

"""
    gen_gitignore(pkg_dir::AbstractString, t::Template) -> Vector{String}

Create a `.gitignore` in `pkg_dir`.

# Arguments
* `pkg_dir::AbstractString`: The directory in which the files will be generated.
* `t::Template`: The template whose .gitignore we are generating.

Returns an array of generated file/directory names.
"""
function gen_gitignore(pkg_dir::AbstractString, t::Template)
    pkg = basename(pkg_dir)
    init = [".DS_Store", "/dev/"]
    entries = mapfoldl(p -> p.gitignore, append!, values(t.plugins); init=init)
    if !t.manifest && !in("Manifest.toml", entries)
        push!(entries, "/Manifest.toml")  # Only ignore manifests at the repo root.
    end
    unique!(sort!(entries))
    text = join(entries, "\n")

    gen_file(joinpath(pkg_dir, ".gitignore"), text)
    files = [".gitignore"]
    t.manifest && push!(files, "Manifest.toml")
    return files
end

"""
    gen_license(pkg_dir::AbstractString, t::Template) -> Vector{String}

Create a license in `pkg_dir`.

# Arguments
* `pkg_dir::AbstractString`: The directory in which the files will be generated.
* `t::Template`: The template whose LICENSE we are generating.

Returns an array of generated file/directory names.
"""
function gen_license(pkg_dir::AbstractString, t::Template)
    if isempty(t.license)
        return String[]
    end

    text = "Copyright (c) $(year(today())) $(t.authors)\n"
    text *= read_license(t.license)

    gen_file(joinpath(pkg_dir, "LICENSE"), text)
    return ["LICENSE"]
end

"""
    gen_file(file::AbstractString, text::AbstractString) -> Int

Create a new file containing some given text. Always ends the file with a newline.

# Arguments
* `file::AbstractString`: Path to the file to be created.
* `text::AbstractString`: Text to write to the file.

Returns the number of bytes written to the file.
"""
function gen_file(file::AbstractString, text::AbstractString)
    mkpath(dirname(file))
    if !endswith(text , "\n")
        text *= "\n"
    end
    return write(file, text)
end

"""
    version_floor(v::VersionNumber=VERSION) -> String

Format the given Julia version.

# Keyword arguments
* `v::VersionNumber=VERSION`: Version to floor.

Returns "major.minor" for the most recent release version relative to v. For prereleases
with v.minor == v.patch == 0, returns "major.minor-".
"""
function version_floor(v::VersionNumber=VERSION)
    return if isempty(v.prerelease) || v.patch > 0
        "$(v.major).$(v.minor)"
    else
        "$(v.major).$(v.minor)-"
    end
end

"""
    substitute(template::AbstractString, view::Dict{String, Any}) -> String
    substitute(
        template::AbstractString,
        pkg_template::Template;
        view::Dict{String, Any}=Dict{String, Any}(),
    ) -> String

Replace placeholders in `template` with values in `view` via
[`Mustache`](https://github.com/jverzani/Mustache.jl). `template` is not modified.
If `pkg_template` is supplied, some default replacements are also performed.

For information on how to structure `template`, see "Defining Template Files" section in
[Custom Plugins](@ref).

**Note**: Conditionals in `template` without a corresponding key in `view` won't error,
but will simply be evaluated as false.
"""
substitute(template::AbstractString, view::Dict{String, Any}) = render(template, view)

function substitute(
    template::AbstractString,
    pkg_template::Template;
    view::Dict{String, Any}=Dict{String, Any}(),
)
    # Don't use version_floor here because we don't want the trailing '-' on prereleases.
    v = pkg_template.julia_version
    d = Dict{String, Any}(
        "USER" => pkg_template.user,
        "VERSION" => "$(v.major).$(v.minor)",
        "DOCUMENTER" => any(map(p -> isa(p, Documenter), values(pkg_template.plugins))),
        "CODECOV" => haskey(pkg_template.plugins, Codecov),
        "COVERALLS" => haskey(pkg_template.plugins, Coveralls),
    )

    # d["AFTER"] is true whenever something needs to occur in a CI "after_script".
    d["AFTER"] = d["DOCUMENTER"] || d["CODECOV"] || d["COVERALLS"]

    # d["COVERAGE"] is true whenever a coverage plugin is enabled.
    # TODO: This doesn't handle user-defined coverage plugins.
    # Maybe we need an abstract CoveragePlugin <: GenericPlugin?
    d["COVERAGE"] = |(
        d["CODECOV"],
        d["COVERALLS"],
        haskey(pkg_template.plugins, GitLabCI) && pkg_template.plugins[GitLabCI].coverage,
    )
    return substitute(template, merge(d, view))
end

splitjl(pkg::AbstractString) = endswith(pkg, ".jl") ? pkg[1:end-3] : pkg
