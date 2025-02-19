# The code in this file is a small port from scikit-learn's and numpy's
# library which is distributed under the 3-Clause BSD license.
# The rest of DecisionTree_modified.jl is released under the MIT license.

# written by Poom Chiarawongse <eight1911@gmail.com>

module treeclassifier
include("../util.jl")
using Random: Random
using StatsBase

export fit

mutable struct NodeMeta{S}
    l::NodeMeta{S}      # right child
    r::NodeMeta{S}      # left child
    label::Int              # most likely label
    feature::Int            # feature used for splitting
    threshold::S                # threshold value
    eveloss::Vector{Float64}               # second best feature
    threbound::Vector{Float64}          # second best threshold
    # opt_threshold::Vector{S}   # optimal threshold
    # opt_purity::Vector{S}      # optimal purity
    is_leaf::Bool
    depth::Int
    region::UnitRange{Int}     # a slice of the samples used to decide the split of the node
    features::Vector{Int}      # a list of features not known to be constant
    split_at::Int              # index of samples
    node_impurity::Float64
    function NodeMeta{S}(
        features::Vector{Int},
        region::UnitRange{Int},
        depth::Int,
        node_impurity::Float64=0.0,
    ) where {S}
        node = new{S}()
        node.depth = depth
        node.region = region
        node.features = features
        node.is_leaf = false
        node.node_impurity = node_impurity
        node
    end
end

struct Tree{S,T}
    root::NodeMeta{S}
    list::Vector{T}
    labels::Vector{Int}
end

# find an optimal split that satisfy the given constraints
# (max_depth, min_samples_split, min_purity_increase)
function _split!(
    X::AbstractMatrix{S},   # the feature array
    Y::AbstractVector{Int}, # the label array
    W::AbstractVector{U},   # the weight vector
    purity_function::Function,
    node::NodeMeta{S}, # the node to split
    max_features::Int,         # number of features to consider
    max_depth::Int,            # the maximum depth of the resultant tree
    min_samples_leaf::Int,            # the minimum number of samples each leaf needs to have
    min_samples_split::Int,           # the minimum number of samples in needed for a split
    min_purity_increase::Float64,     # minimum purity needed for a split
    indX::AbstractVector{Int}, # an array of sample indices, 1:n_samples
    # we split using samples in indX[node.region]
    # the six arrays below are given for optimization purposes
    nc::AbstractVector{U},    # nc maintains a dictionary of all labels in the samples
    ncl::AbstractVector{U},   # ncl maintains the counts of labels on the left
    ncr::AbstractVector{U},   # ncr maintains the counts of labels on the right
    Xf::AbstractVector{S},
    Yf::AbstractVector{Int},
    Wf::AbstractVector{U},  #build_tree, Wf = nothing 
    rng::Random.AbstractRNG,
) where {S,U}
    region = node.region
    n_samples = length(region)
    n_classes = length(nc)
    nc[:] .= zero(U)
    @simd for i in region
        @inbounds nc[Y[indX[i]]] += W[indX[i]]
    end
    nt = sum(nc)
    node.label = argmax(nc)
    # node.node_impurity = nt * purity_function(nc, nt)
    node.node_impurity = nt - maximum(nc)
    if (
        min_samples_leaf * 2 > n_samples ||
        min_samples_split > n_samples ||
        max_depth <= node.depth ||
        nc[node.label] == nt
    )
        node.is_leaf = true
        return nothing
    end

    r_start = region.start - 1
    features = node.features
    n_features = length(features)
    best_purity = typemin(U)
    best_feature = -1
    eveloss = -Inf * ones(Int, n_features)
    threshold_lo = X[1]
    threshold_hi = X[1]
    be_purity = -Inf * ones(Float64, n_features)


    indf = 1
    # the number of new constants found during this split
    n_const = 0
    # true if every feature is constant
    unsplittable = true
    # the number of non constant features we will see if
    # only sample n_features used features
    # is a hypergeometric random variable
    total_features = size(X, 2)
    # this is the total number of features that we expect to not
    # be one of the known constant features. since we know exactly
    # what the non constant features are, we can sample at 'non_consts_used'
    # non constant features instead of going through every feature randomly.
    non_consts_used = util.hypergeometric(
        n_features, total_features - n_features, max_features, rng
    )
    k = 0
    @inbounds while (unsplittable || indf <= non_consts_used) && indf <= n_features
        feature = let
            indr = rand(rng, indf:n_features)
            features[indf], features[indr] = features[indr], features[indf]
            features[indf]
            k += 1
        end

        # in the begining, every node is on right of the threshold
        ncl[:] .= zero(U)
        ncr[:] = nc
        @simd for i in 1:n_samples
            Xf[i] = X[indX[i+r_start], feature]
        end

        # sort Yf and indX by Xf
        util.q_bi_sort!(Xf, indX, 1, n_samples, r_start)
        @simd for i in 1:n_samples
            Yf[i] = Y[indX[i+r_start]]
            Wf[i] = W[indX[i+r_start]]
        end

        hi = 0
        nl, nr = zero(U), nt
        is_constant = true
        last_f = Xf[1]
        delta = 0
        while hi < n_samples
            lo = hi + 1
            curr_f = Xf[lo]

            (lo != 1) && (is_constant = false)
            # honor min_samples_leaf
            # if nl >= min_samples_leaf && nr >= min_samples_leaf
            # @assert nl == lo-1,
            # @assert nr == n_samples - (lo-1) == n_samples - lo + 1

            if lo - 1 >= min_samples_leaf && n_samples - (lo - 1) >= min_samples_leaf
                unsplittable = false
                # purity = -(nl * purity_function(ncl, nl) + nr * purity_function(ncr, nr))
                purity = -(nt - maximum(ncl) - maximum(ncr))
                if purity > be_purity[feature]
                    be_purity[feature] = purity
                    eveloss[feature] = purity
                end
                if purity > best_purity && !isapprox(purity, best_purity)
                    threshold_lo = last_f
                    threshold_hi = curr_f
                    best_purity = purity
                    best_feature = feature
                    # println("Feature: ", feature, " lo: ", lo, " best_Purity: ", best_purity, " delta: ", delta, " Wf: ", Wf[lo], " Yf: ", Yf[lo])
                end
                delta = max(Int(best_purity - purity), 0)
                # delta = max(ceil(best_purity - purity), 0)
            end
            indnext = min(lo + delta, n_samples)
            ind_jump = searchsortedlast(Xf, Xf[indnext], indnext, n_samples, Base.Order.Forward)
            hi = ind_jump

            # fill ncl and ncr in the direction
            # that would require the smaller number of iterations
            # i.e., hi - lo < n_samples - hi

            ncro = copy(ncr)

            if (hi << 1) < n_samples + lo # ncr: number of each class exists in right set
                @simd for i in lo:hi
                    ncr[Yf[i]] -= Wf[i]
                end
            else
                ncr[:] .= zero(U)
                @simd for i in (hi+1):n_samples
                    ncr[Yf[i]] += Wf[i]
                end
            end


            dnc = ncro - ncr
            while maximum(dnc) - minimum(dnc) < delta && hi < n_samples
                hi += 1
                dnc[Yf[hi]] += 1
                ncr[Yf[hi]] -= Wf[hi]
            end 


            nr = zero(U)
            @simd for lab in 1:n_classes
                nr += ncr[lab]  # nr: number of samples in right set
                ncl[lab] = nc[lab] - ncr[lab] #ncr: number of each class exists in left set
            end
            nl = nt - nr

            last_f = Xf[hi]#curr_f
        end
        #println("Feature: ", feature, " Iter: ", iter, " k: ", k)
        # keep track of constant features to be used later.
        if is_constant
            n_const += 1
            features[indf], features[n_const] = features[n_const], features[indf]
        end

        indf += 1
    end

    # no splits honor min_samples_leaf
    @inbounds if (
        unsplittable || (best_purity + node.node_impurity < min_purity_increase * nt)
    )
        node.is_leaf = true
        return nothing   ### stop as a leaf node
    else
        @simd for i in 1:n_samples
            Xf[i] = X[indX[i+r_start], best_feature]
        end

        try
            node.threshold = (threshold_lo + threshold_hi) / 2.0
            node.threbound = [threshold_lo, threshold_hi]
        catch
            node.threshold = threshold_hi
            node.threbound = [threshold_hi, threshold_hi]
        end
        # split the samples into two parts: ones that are greater than
        # the threshold and ones that are less than or equal to the threshold
        #                                 ---------------------
        # (so we partition at threshold_lo instead of node.threshold)
        node.split_at = util.partition!(indX, Xf, threshold_lo, region)
        node.feature = best_feature
        node.eveloss = eveloss
        node.features = features[(n_const+1):n_features]
    end
    return _split!
end


@inline function fork!(node::NodeMeta{S}) where {S}
    ind = node.split_at
    region = node.region
    features = node.features
    # no need to copy because we will copy at the end
    node.l = NodeMeta{S}(features, region[1:ind], node.depth + 1)
    node.r = NodeMeta{S}(features, region[(ind+1):end], node.depth + 1)
end

function _fit(
    X::AbstractMatrix{S},
    Y::AbstractVector{Int},
    W::AbstractVector{U},
    loss::Function,
    n_classes::Int,
    max_features::Int,
    max_depth::Int,
    min_samples_leaf::Int,
    min_samples_split::Int,
    min_purity_increase::Float64,
    rng=Random.GLOBAL_RNG::Random.AbstractRNG,
) where {S,U}
    n_samples, n_features = size(X)
    nc = Array{U}(undef, n_classes)
    ncl = Array{U}(undef, n_classes)
    ncr = Array{U}(undef, n_classes)
    Wf = Array{U}(undef, n_samples)
    Xf = Array{S}(undef, n_samples)
    Yf = Array{Int}(undef, n_samples)
    indX = collect(1:n_samples)
    root = NodeMeta{S}(collect(1:n_features), 1:n_samples, 0)
    stack = NodeMeta{S}[root]
    @inbounds while length(stack) > 0
        node = pop!(stack)
        _split!(
            X,
            Y,
            W,
            loss,
            node,
            max_features,
            max_depth,
            min_samples_leaf,
            min_samples_split,
            min_purity_increase,
            indX,
            nc,
            ncl,
            ncr,
            Xf,
            Yf,
            Wf,
            rng,
        )
        if !node.is_leaf
            fork!(node)
            push!(stack, node.r)
            push!(stack, node.l)
        end
    end

    return (root, indX)
end

function fit(;
    X::AbstractMatrix{S},
    Y::AbstractVector{T},
    W::Union{Nothing,AbstractVector{U}},
    loss=util.normal_loss::Function,
    max_features::Int,
    max_depth::Int,
    min_samples_leaf::Int,
    min_samples_split::Int,
    min_purity_increase::Float64,
    rng=Random.GLOBAL_RNG::Random.AbstractRNG,
) where {S,T,U}
    n_samples, n_features = size(X)
    list, Y_ = util.assign(Y)
    if isnothing(W)
        W = fill(1, n_samples)
    end

    util.check_input(
        X,
        Y,
        W,
        max_features,
        max_depth,
        min_samples_leaf,
        min_samples_split,
        min_purity_increase,
    )

    root, indX = _fit(
        X,
        Y_,
        W,
        loss,
        length(list),
        max_features,
        max_depth,
        min_samples_leaf,
        min_samples_split,
        min_purity_increase,
        rng,
    )

    return Tree{S,T}(root, list, indX)
end
end
