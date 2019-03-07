const DOCUMENTER_UUID = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
const RESERVED_KWS = [:modules, :format, :pages, :repo, :sitename, :authors, :assets]

"""
    Documenter{T<:Union{GitLabCI, TravisCI, Nothing}}(;
        assets::Vector{<:AbstractString}=String[],
        kwargs::Union{Dict, NamedTuple}=Dict(),
    ) -> Documenter{T}

Add `Documenter{T}` to a template's plugins to add support for documentation
generation via [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl), and deployment
via `T`, where `T` is some supported CI plugin, or `Nothing` to only support local
documentation builds.

!!! note
    If deploying documentation with Travis CI, don't forget to complete the required
    configuration (see
    [here](https://juliadocs.github.io/Documenter.jl/stable/man/hosting/#SSH-Deploy-Keys-1)).
"""
struct Documenter{T<:Union{GitLabCI, TravisCI, Nothing}} <: Plugin
    assets::Vector{String}
    kwargs::Dict{Symbol, Any}

    function Documenter{T}(;
        assets::Vector{<:AbstractString}=String[],
        kwargs=Dict(),
    ) where T <: Union{GitLabCI, TravisCI, Nothing}
        map!(abspath, assets, assets)
        foreach(assets) do file
            isfile(file) || throw(ArgumentError("Asset file $file not exist"))
        end

        kwargs = Dict{Symbol, Any}(pairs(kwargs))
        foreach(kwargs) do (k, v)
            k in RESERVED_KWS && throw(ArgumentError("makedocs keyword $k is reserved"))
        end

        return new(assets, kwargs)
    end
end

# Windows Git also recognizes these paths.
gitignore(::Documenter) = ["/docs/build/", "/docs/site/"]

badges(::Documenter{Nothing}) = Badge[]

function badges(::Documenter)
    return [
        Badge(
            "Stable",
            "https://img.shields.io/badge/docs-stable-blue.svg",
            "https://{{USER}}.github.io/{{PKGNAME}}.jl/stable",
        ),
        Badge(
            "Dev",
            "https://img.shields.io/badge/docs-dev-blue.svg",
            "https://{{USER}}.github.io/{{PKGNAME}}.jl/dev",
        ),
    ]
end

function badges(::Documenter{GitLabCI})
    return [Badge(
        "Dev",
        "https://img.shields.io/badge/docs-dev-blue.svg",
        "https://{{USER}}.gitlab.io/{{PKGNAME}}.jl/dev"
    )]
end

# Add the deploydocs section to make.jl, only for Travis CI.
maybe_deploydocs(::Documenter, ::Template, ::AbstractString) = nothing
function maybe_deploydocs(::Documenter{TravisCI}, t::Template, pkg_name::AbstractString)
    make = joinpath(t.dir, pkg_name, "docs", "make.jl")
    s = """

        deploydocs(;
            repo="$(t.host)/$(t.user)/$pkg_name.jl",
        )
        """
    open(io -> print(io, s), make, "a")
end

function gen_plugin(p::Documenter, t::Template, pkg_name::AbstractString)
    path = joinpath(t.dir, pkg_name)
    docs_dir = joinpath(path, "docs")
    mkpath(docs_dir)

    # Create the documentation project.
    proj = Base.current_project()
    try
        Pkg.activate(docs_dir)
        Pkg.add(PackageSpec(; name="Documenter", uuid=DOCUMENTER_UUID))
    finally
        proj === nothing ? Pkg.activate() : Pkg.activate(proj)
    end

    tab = repeat(" ", 4)
    assets_string = if isempty(p.assets)
        "[]"
    else
        # Copy the files and create the list.
        # We want something that looks like the following:
        # [
        #         assets/file1,
        #         assets/file2,
        #     ]

        mkpath(joinpath(docs_dir, "src", "assets"))
        s = "[\n"
        foreach(p.assets) do asset
            cp(asset, joinpath(docs_dir, "src", "assets", basename(asset)))
            s *= """$(tab^2)"assets/$(basename(asset))",\n"""
        end

        s * tab * "]"
    end

    kwargs_string = if isempty(p.kwargs)
        ""
    else
        # We want something that looks like the following:
        #     key1="val1",
        #     key2="val2",
        #
        join(string(tab, k, "=", repr(v) for (k, v) in p.kwargs), ",\n")
    end

    make = """
        using Documenter, $pkg_name

        makedocs(;
            modules=[$pkg_name],
            format=Documenter.HTML(),
            pages=[
                "Home" => "index.md",
            ],
            repo="https://$(t.host)/$(t.user)/$pkg_name.jl/blob/{commit}{path}#L{line}",
            sitename="$pkg_name.jl",
            authors="$(t.authors)",
            assets=$assets_string,
        $kwargs_string)
        """
    docs = """
        # $pkg_name.jl

        ```@index
        ```

        ```@autodocs
        Modules = [$pkg_name]
        ```
        """

    gen_file(joinpath(docs_dir, "make.jl"), make)
    maybe_deploydocs(p, t, pkg_name)
    gen_file(joinpath(docs_dir, "src", "index.md"), docs)

    return ["docs/"]
end

function interactive(T::Type{<:Documenter})
    print("$T: Enter any Documenter asset files (separated by spaces) [none]: ")
    assets = split(readline())

    println("$T: Enter any extra makedocs key-value pairs (joined by '=') [none]")
    kwargs = Dict{Symbol, Any}()
    line = map(split(readline())) do kv
        k, v = split(kv, "="; limit=2)
        kwargs[Symbol(k)] = eval(Meta.parse(v))
    end

    return T(; assets=assets, kwargs=kwargs)
end

function Base.show(io::IO, p::Documenter)
    T = typeof(p)
    as = length(p.assets)
    ks = length(p.kwargs)
    print(io, "$T: $as extra asset(s), $ks extra keyword(s)")
end
