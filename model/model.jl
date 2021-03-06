using Distributions
using Random
using Parameters
# ---------- Basics ---------- #

"Bayesian Drift Diffusion Model"
@with_kw struct BDDM
    N::Int = 2                            # number of items
    base_precision::Float64 = 0.3         # precision per second of attended item with confidence=0
    attention_factor::Float64 = 1.        # down-weighting of precision for unattended item (less than 1)
    cost::Float64 = 0.1                   # cost per second
    risk_aversion::Float64 = 0            # scales penalty for variance of chosen item
    confidence_slope::Float64 = 0.        # how much does confidence increase your precision?
    subjective_offset::Float64 = 0.       # additive offset to base_precision for subjective confidence
    subjective_slope::Float64 = 1.        # scales confidence_slope for subjective confidence
    prior_mean::Float64 = 0.
    prior_precision::Float64 = 1.
    tmp::Vector{Float64} = zeros(N) # implementation detail, for memory-efficiency
end

"The state of the BDDM."
struct State
    μ::Vector{Float64}
    λ::Vector{Float64}
end
State(m::BDDM) = State(fill(m.prior_mean, m.N), fill(m.prior_precision, m.N))
Base.copy(s::State) = State(copy(s.μ), copy(s.λ))

"A single choice trial"
abstract type Trial end

struct HumanTrial <: Trial
    value::Vector{Float64}
    confidence::Vector{Float64}
    presentation_distributions::Vector{Distribution}  # presentation time distribution
    real_presentation_times::Vector{Int}  # actual presentation times
    subject::Int
    choice::Int
    rt::Int
    dt::Float64
end

struct SimTrial <: Trial
    value::Vector{Float64}
    confidence::Vector{Float64}
    presentation_distributions::Vector{Distribution}
    dt::Float64
end
function SimTrial(;value=randn(2), 
                   confidence=rand(1.:5, 2),
                   presentation_distributions = shuffle!([Normal(0.2, 0.05), Normal(0.5, 0.1)]),
                   dt = 0.025)
    SimTrial(value, confidence, presentation_distributions, dt)
end

SimTrial(t::HumanTrial) = SimTrial(t.value, t.confidence, t.presentation_distributions, t.dt)

# ---------- Updating ---------- #

"Returns updated mean and precision given a prior and observation."
function bayes_update_normal(μ, λ, obs, λ_obs)
    λ1 = λ + λ_obs
    μ1 = (obs * λ_obs + μ * λ) / λ1
    (μ1, λ1)
end

"Take one step of the BDDM.

Draws samples of each item, centered on their true values with precision based
on confidence and attention. Integrates these samples into the current belief
State by Bayesian inference. The precision used to generate the samples (λ_objective)
may differ from the precision assumed when performing the posterior update (λ_subjective).
"
function update!(m::BDDM, s::State, true_value::Vector, λ_objective::Vector, λ_subjective::Vector)
    for i in eachindex(λ_objective)
        λ_objective[i] == 0 && continue  # no update
        σ_obs = λ_objective[i] ^ -0.5
        obs = true_value[i] + σ_obs * randn()
        s.μ[i], s.λ[i] = bayes_update_normal(s.μ[i], s.λ[i], obs, λ_subjective[i])
    end
end

# ---------- Choice and value ---------- #

"Reward attained when terminating sampling.

Each item's value is penalized by its uncertainty (a non-standard form of risk
aversion). The item with maximal (risk-discounted) value is chosen, and the
(risk-discounted) expected value of the item is received as a reward.
"
function term_reward(m::BDDM, s::State)
    maximum(subjective_values(m, s))
end

function subjective_values(m::BDDM, s::State)
    v = m.tmp  # use pre-allocated array for efficiency
    @. v = s.μ - m.risk_aversion * s.λ ^ -0.5
end

# ---------- Attention ---------- #

function set_attention!(attention::Vector, m::BDDM, attended_item::Int, first_fix::Bool)
    unattended = (first_fix ? 0 : m.attention_factor)
    for i in eachindex(attention)
        attention[i] = i == attended_item ? 1. : unattended
    end
end

function make_switches(t::SimTrial)
    switching = t.presentation_distributions |> enumerate |> Iterators.cycle |> Iterators.Stateful
    function switch()
        item, dist = first(switching)
        duration = max(1, round(Int, rand(dist) / t.dt))
        item, duration
    end
end

function make_switches(t::HumanTrial)
    switching = zip(Iterators.cycle(eachindex(t.value)), t.real_presentation_times) |> Iterators.Stateful
    function switch()
        first(switching)
    end
end

# ---------- Stopping policy ---------- #

"A Policy decides when to stop sampling."
abstract type Policy end

"A Policy endorsed by Young Gunz."
struct CantStopWontStop <: Policy end
stop(pol::CantStopWontStop, s::State, t::Trial) = false
initialize!(pol::CantStopWontStop, t::Trial) = nothing

# ---------- Simulation ---------- #

"Precision of one sample, including confidence but not attention"
function objective_precision(m, t)
    @. t.dt * (m.base_precision + m.confidence_slope * t.confidence)
end

"*Perceived* precision of one sample"
function subjective_precision(m, t)
    @. t.dt * (m.base_precision + m.subjective_offset + m.subjective_slope * m.confidence_slope * t.confidence)
end

"Simulates a choice trial with a given BDDM and stopping Policy."
function simulate(m::BDDM, t::Trial; pol::Policy=DirectedCognition(m), s=State(m), max_step=cld(20, t.dt), 
                  save_states=false, save_presentation=false)
    if t isa HumanTrial
        #error("Trying to simulate a HumanTrial")
        max_step = min(max_step, t.rt)
    end
    initialize!(pol, t)
    switch = make_switches(t)
    attended_item, time_to_switch = switch()
    timeout = false
    first_fix = true
    time_step = 0
    states = State[]
    presentation_durations = save_presentation ? [time_to_switch] : nothing
    obj_conf = objective_precision(m, t)
    subj_conf = subjective_precision(m, t)

    # objective_precision = @. m.base_precision * t.confidence ^ m.confidence_slope
    # subjective_precision = @. (m.base_precision + m.over_confidence_intercept) + 
                               # (m.confidence_slope + m.over_confidence_slope) * t.confidence

    attention = zeros(m.N); λ_objective = zeros(m.N); λ_subjective = zeros(m.N)

    while true
        save_states && push!(states, copy(s))
        time_step += 1
        if time_to_switch == 0
            attended_item, time_to_switch = switch()
            save_presentation && push!(presentation_durations, time_to_switch)
            first_fix = false
        end
        set_attention!(attention, m, attended_item, first_fix)
        @. λ_objective = obj_conf * attention
        @. λ_subjective = subj_conf * attention
        update!(m, s, t.value, λ_objective, λ_subjective)
        time_to_switch -= 1
        stop(pol, s, t) && break
        if time_step == max_step
            timeout = true
            break
        end
    end
    if save_presentation
        presentation_durations[end] -= time_to_switch  # remaining fixation time
    end
    value, choice = findmax(subjective_values(m, s))
    reward = value - time_step * t.dt * m.cost
    push!(states, s)
    (;choice, time_step, reward, states, presentation_durations, timeout)
end

# simulate(m::BDDM, pol::Policy, t::HumanTrial; kws...) = simulate(m, pol; t, max_step=t.rt, kws...)
# simulate(m::BDDM, pol::Policy, t::HumanTrial; kws...) = simulate(m, pol; t, max_step=t.rt, kws...)
# simulate(m::BDDM, t::HumanTrial; kws...) = simulate(m, t; max_step=t.rt, kws...)

# ---------- Miscellaneous ---------- #

# namedtuple(t::Trial) = (
#     val1 = t.value[1],
#     val2 = t.value[2],
#     conf1 = t.confidence[1],
#     conf2 = t.confidence[2],
# )

# namedtuple(m::BDDM) = (
#     base_precision = m.base_precision,
#     attention_factor = m.attention_factor,
#     cost = m.cost,
#     risk_aversion = m.risk_aversion,
#     over_confidence_slope = m.over_confidence_slope,
#     over_confidence_intercept = m.over_confidence_intercept,
#     prior_mean = m.prior_mean,
#     prior_precision = m.prior_precision
# )
