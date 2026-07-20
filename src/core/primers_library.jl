# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

## Primers library
# Loads, normalises, serialises and validates config/primers.yml: the Forward
# and Reverse primer vocabularies and the Pairs composed from them. The
# validation rules themselves live in Validation (one source of truth shared
# with the environment validator); this module reuses them.
module PrimersLibrary

using YAML
using ..Validation

# An empty document, used when the file is absent. A malformed file does NOT
# reach this: load raises rather than degrading to it, since an empty document
# is exactly what a Save would then write over the real primers.
_empty() = Dict{String,Any}("Forward" => Dict{String,Any}(),
                            "Reverse" => Dict{String,Any}(),
                            "Pairs"   => Any[])

# Coerce a value that is stringified into the document. `string(nothing)` is the
# literal "nothing", so an idiomatic YAML null (`~`) would otherwise be written
# back as that four-letter string rather than as the absence it spells. Absent
# and null alike mean "no value here", so both become the empty string, which the
# rules below already read as missing.
_str_or_empty(v) = isnothing(v) ? "" : string(v)

# Coerce a name-to-sequence map's keys to String. A numeric primer name parses
# as an Int64 under YAML; a later name-keyed lookup would dangle otherwise.
_strmap(m) = m isa AbstractDict ?
    Dict{String,Any}(_str_or_empty(k) => v for (k, v) in m) : Dict{String,Any}()

_empty_pair() = Dict{String,Any}("name" => "", "forward" => "", "reverse" => "")

# Convert one native pair entry into the canonical flat shape, returning EVERY
# pair it carries. An entry is meant to be a single-key mapping name => [fwd,
# rev], and a well-formed one yields exactly one pair.
#
# A multi-key entry is a malformed document, not a single pair: primers.yml
# indents a pair's members level with their key, so one missing "- " fuses the
# following pair into the same mapping, which is an ordinary typo rather than an
# exotic one. Returning on the first key discarded every other pair silently, and
# because a mapping iterates in hash order the pair discarded was not even
# predictable; the next Save then wrote the survivor alone over the real file.
# Surfacing every key loses nothing, shows the user both pairs, and makes a Save
# rewrite them in the canonical one-mapping-per-pair shape. It also reconciles
# the two readers of this document: Validation.primer_document_errors already
# iterates every key of the entry, so returning one here made the shared rules
# and this module contradict each other about what the file contains.
#
# A malformed entry is otherwise represented leniently, with empty strings where
# members are missing, so validate can flag it rather than load dropping it.
function _flatten_pairs(entry)
    entry isa AbstractDict || return Any[_empty_pair()]
    out = Any[]
    for (name, members) in entry
        fwd = members isa AbstractVector && length(members) >= 1 ? _str_or_empty(members[1]) : ""
        rev = members isa AbstractVector && length(members) >= 2 ? _str_or_empty(members[2]) : ""
        push!(out, Dict{String,Any}("name" => _str_or_empty(name), "forward" => fwd, "reverse" => rev))
    end
    isempty(out) && return Any[_empty_pair()]
    # The keys of one fused entry are sorted, though Pairs itself is not: the
    # fusion has already destroyed whatever order they were written in, since a
    # mapping keeps none, so sorting gives a stable reading rather than the
    # hash-order shuffle. A well-formed entry has one key, so this never
    # reorders anything; the sequence order of Pairs proper is untouched.
    sort!(out; by = p -> p["name"])
    out
end

# Normalise a raw/native document (as parsed from YAML) to the canonical shape.
function normalise(raw::AbstractDict)
    pairs_raw = get(raw, "Pairs", Any[])
    pairs = Any[]
    if pairs_raw isa AbstractVector
        for e in pairs_raw
            append!(pairs, _flatten_pairs(e))
        end
    end
    Dict{String,Any}(
        "Forward" => _strmap(get(raw, "Forward", Dict{String,Any}())),
        "Reverse" => _strmap(get(raw, "Reverse", Dict{String,Any}())),
        "Pairs"   => pairs,
    )
end

# The sections a primers document carries, and the shape each must have. These
# are exactly the sections validate demands of a document, so a file that fails
# this check is one no Save could ever have written.
const _SECTIONS = (("Forward", AbstractDict, "a mapping of name to sequence"),
                   ("Reverse", AbstractDict, "a mapping of name to sequence"),
                   ("Pairs",   AbstractVector, "a list"))

# Why `raw` is not a primers document, or nothing when it is one.
#
# Presence is checked, not merely type. `get` defaults only an ABSENT key, so a
# section misspelt (`Pares:`) or nulled (`Pairs: ~`) reads as no pairs at all
# rather than as the error it is; that is the same laundering a non-mapping file
# performs, arriving by a different route.
#
# An empty-but-present section is legitimate and must stay so: `Pairs: []` and
# `Forward: {}` say "no pairs" and "no primers" unambiguously, and deleting
# everything is a real edit. Only absence and the wrong type are refused.
function _document_error(raw)
    raw isa AbstractDict || return "it is not a YAML mapping"
    for (name, T, shape) in _SECTIONS
        haskey(raw, name) || return "it has no '$name:' section"
        raw[name] isa T || return "its '$name:' section is not $shape"
    end
    nothing
end

# Load the document. A MISSING file yields an empty document, so a fresh install
# behaves as though no primers are defined rather than erroring.
#
# A file that exists but is not a primers document deliberately raises rather
# than degrading to an empty one, whether it is unparseable YAML or merely
# structurally wrong. Degrading would be silent data loss: the editor would
# render the file as "no primers", an empty document breaks no validation rule,
# and the user's next Save would overwrite their real primers with nothing. A
# caller that must not throw catches this at its own boundary and reports the
# file as unreadable; see the primers routes, which turn it into a 400 naming
# the file.
#
# The structural case needs the guard as much as the unparseable one, and only
# the write gate's REQUEST path was ever covered: a malformed section submitted
# by a client is refused by validate, but the same shape arriving from the FILE
# was laundered into a valid empty document before the gate could see it, so the
# gate never fired.
function load(path::String)
    isfile(path) || return _empty()
    raw = YAML.load_file(path)
    problem = _document_error(raw)
    isnothing(problem) || error("$path is not a primers document: $problem")
    normalise(raw)
end

# Convert the canonical shape back to the native file shape for YAML.write:
# Pairs becomes a list of single-key mappings name => [forward, reverse].
function to_yaml_doc(doc::AbstractDict)
    pairs = Any[]
    for p in Validation._seq(get(doc, "Pairs", nothing))
        p isa AbstractDict || continue
        name = _str_or_empty(get(p, "name", ""))
        fwd  = _str_or_empty(get(p, "forward", ""))
        rev  = _str_or_empty(get(p, "reverse", ""))
        push!(pairs, Dict{String,Any}(name => Any[fwd, rev]))
    end
    Dict{String,Any}(
        "Forward" => _strmap(get(doc, "Forward", Dict{String,Any}())),
        "Reverse" => _strmap(get(doc, "Reverse", Dict{String,Any}())),
        "Pairs"   => pairs,
    )
end

# Pair names in document order.
function pair_names(doc::AbstractDict)
    names = String[]
    for p in Validation._seq(get(doc, "Pairs", nothing))
        p isa AbstractDict && push!(names, _str_or_empty(get(p, "name", "")))
    end
    names
end

# Validate a canonical document. Delegates to the shared rule function so the
# environment validator and this module cannot disagree on what a valid primers
# document is. Never throws.
#
# The rules below are added on top, and only here. Each is a WRITE-time rule, not
# a file-validity rule: each is meaningless or destructive in a new document, but
# adding it to the shared rules would fail a primers.yml that validated
# yesterday, so it is applied where new documents are written and nowhere else.
#
# `Pairs` is checked before anything else, and a malformed `Pairs` returns
# immediately rather than falling through to _seq: _seq exists to keep genuine
# iteration from throwing on a null inner sequence, not to make a malformed
# top-level section look like a deliberately emptied one. Coercing it here
# would be the same mistake load's docstring above refuses to make: an empty
# document breaks no validation rule, so the write gate would wave through a
# document that wipes every pair on save. Deleting every pair already has an
# unambiguous spelling, the empty list, so nothing legitimate is lost by
# rejecting anything else. `Forward` and `Reverse` are checked the same way,
# because a scalar or a list there would serialise nonsense just as readily.
function validate(doc::AbstractDict; native::AbstractDict=to_yaml_doc(doc))
    errors = String[]
    for section in ("Forward", "Reverse")
        sect = get(doc, section, nothing)
        sect isa AbstractDict ||
            push!(errors, "the $section section must be a mapping")
    end

    pairs = get(doc, "Pairs", nothing)
    pairs isa AbstractVector || begin
        push!(errors, "the Pairs section must be a list")
        return errors
    end

    append!(errors, Validation.primer_document_errors(native))
    for section in ("Forward", "Reverse")
        primers = get(doc, section, Dict{String,Any}())
        primers isa AbstractDict || continue
        for (name, seq) in primers
            seq isa AbstractString && isempty(strip(seq)) &&
                push!(errors, "primer '$name' has an empty sequence")
        end
    end
    errors
end

end # module
