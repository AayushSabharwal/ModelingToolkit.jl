module StructuralTransformations

using Setfield: @set!, @set
using UnPack: @unpack

using Symbolics: unwrap, linear_expansion
using SymbolicUtils
using SymbolicUtils.Code
using SymbolicUtils.Rewriters
using SymbolicUtils: similarterm, istree

using ModelingToolkit
using ModelingToolkit: ODESystem, AbstractSystem, var_from_nested_derivative, Differential,
                       states, equations, vars, Symbolic, diff2term, value,
                       operation, arguments, Sym, Term, simplify, solve_for,
                       isdiffeq, isdifferential, isinput,
                       empty_substitutions, get_substitutions,
                       get_structure, get_iv, independent_variables,
                       has_structure, defaults, InvalidSystemException,
                       ExtraEquationsSystemException,
                       ExtraVariablesSystemException,
                       get_postprocess_fbody, vars!,
                       IncrementalCycleTracker, add_edge_checked!, topological_sort,
                       invalidate_cache!, Substitutions

using ModelingToolkit.BipartiteGraphs
import .BipartiteGraphs: invview
using Graphs
using ModelingToolkit.SystemStructures
using ModelingToolkit.SystemStructures: algeqs

using ModelingToolkit.DiffEqBase
using ModelingToolkit.StaticArrays
using ModelingToolkit: @RuntimeGeneratedFunction, RuntimeGeneratedFunctions

RuntimeGeneratedFunctions.init(@__MODULE__)

using SparseArrays

using NonlinearSolve

export tearing, partial_state_selection, dae_index_lowering, check_consistency
export build_torn_function, build_observed_function, ODAEProblem
export sorted_incidence_matrix, pantelides!, tearing_reassemble, find_solvables!
export tearing_assignments, tearing_substitution
export torn_system_jacobian_sparsity
export full_equations

include("utils.jl")
include("pantelides.jl")
include("bipartite_tearing/modia_tearing.jl")
include("tearing.jl")
include("symbolics_tearing.jl")
include("partial_state_selection.jl")
include("codegen.jl")

end # module
