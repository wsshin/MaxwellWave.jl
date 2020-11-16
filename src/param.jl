export param_arr2mat


param_arr2mat(paramKd::AbsArrComplex,  # material parameter array
              gt₀::AbsVec{GridType},  # grid type of voxel corners; generated by ft2gt.(ft, boundft)
              N::AbsVecInteger,  # size of grid
              ∆l::NTuple{K,AbsVecNumber},  # line segments to multiply with; vectors of length N
              ∆l′::NTuple{K,AbsVecNumber},  # line segments to divide by; vectors of length N
              isbloch::AbsVecBool,  # for K = 3, boundary conditions in x, y, z
              e⁻ⁱᵏᴸ::AbsVecNumber=ones(K);  # for K = 3, Bloch phase factor in x, y, z
              order_cmpfirst::Bool=true  # true to use Cartesian-component-major ordering for more tightly banded matrix
              ) where {K} =
    param_arr2mat(paramKd, SVector{K}(gt₀), SVector{K}(N), ∆l, ∆l′, SVector{K}(isbloch), SVector{K}(e⁻ⁱᵏᴸ), order_cmpfirst=order_cmpfirst)

# Below, N can be retrieved from the size of paramKd or ∆l, but I pass it to make the size
# more explicit.  This also makes the argument list similar to create_mean()'s, which
# includes N because it allows omitting ∆l and ∆l′ and using ∆l = ∆l′ = ones.((N...,)) as
# the default arguments.
function param_arr2mat(paramKd::AbsArrComplex{K₊₂},  # material parameter array
                       gt₀::SVector{K,GridType},  # grid type of voxel corners; generated by ft2gt.(ft, boundft)
                       N::SInt{K},  # size of grid
                       ∆l::NTuple{K,AbsVecNumber},  # line segments to multiply with; vectors of length N
                       ∆l′::NTuple{K,AbsVecNumber},  # line segments to divide by; vectors of length N
                       isbloch::SBool{K},  # for K = 3, boundary conditions in x, y, z
                       e⁻ⁱᵏᴸ::SNumber{K};  # for K = 3, Bloch phase factor in x, y, z
                       order_cmpfirst::Bool=true  # true to use Cartesian-component-major ordering for more tightly banded matrix
                       ) where {K,K₊₂}
    Kf = size(paramKd, K+1)  # field dimension
    @assert size(paramKd,K+2)==Kf

    M = prod(N)  # number voxels

    # Following Oskooi et al.'s 2009 Optics Letters paper, off-diagonal entries of material
    # parameter tensors (e.g., ε) are evaluated at the corners of voxels whose edges are
    # field lines (e.g., E).  Therefore, if w-normal voxel faces are primal grid planes, the
    # w-component of the input fields need to be averaged in the backward direction to be
    # interpolated at voxel corners.
    #
    # Once these interpolated input fields (e.g., Ex) are multiplied with off-diagonal
    # entries (e.g., εzx) of the material parameter tensor, we get the output fields (e.g.,
    # Dzx of Dz = Dzx + Dzy + Dzz = εzx Ex + εzy Ey + εzz Ez) in the direction normal (say
    # v-direction) to the input fields.  These output fields are still at the voxel corners.
    # Now, if the v-normal voxel faces are primal grid planes, the v-component of the output
    # fields need to be averaged in the forward direction to be interpolated at voxel edges.
    #
    # In summary,
    #
    # - to obtain the fields to feed to the off-diagonal entries of material parameter
    # tensors, the w-component of the input fields need to be forward(backward)-averaged
    # along the w-direction if the w-normal voxel faces are dual (primal) grid planes, and
    #
    # - to distribute the resulting output fields in the v(≠w)-direction back to voxel edges,
    # the output fields need to be forward(backward)-averaged along the v-direction if the
    # v-normal voxel faces are primal (dual) grid planes.
    #
    # This means if the w-boundaries are E-field boundaries,
    # - the input E(H)w-field needs to be backward(forward)-averaged in the w-direction, and
    # - the output E(H)w-field needs to be forward(backward)-averaged in the w-direction.
    isfwd_in = gt₀.==DUAL  # SBool{K}; true if input fields need to be forward-averaged
    isfwd_out = gt₀.==PRIM  # SBool{K}; true if output fields need to be backward-averaged

    # For the output averaging, ∆l and ∆l′ are not supplied to create_mean in order to
    # create a simple arithmetic averaging operator.  This is because the area factor matrix
    # multiplied for symmetry to the left of the material parameter matrix multiplies the
    # same area factor to the two fields being averaged.  (See my notes on Jul/18/2018 in
    # MaxwellFDM in Agenda.)
    Mout = create_mean(isfwd_out, N, isbloch, e⁻ⁱᵏᴸ, order_cmpfirst=order_cmpfirst)

    kdiag = 0
    param_mat = create_param_matrix(paramKd, kdiag, N, order_cmpfirst=order_cmpfirst)  # diagonal components of ε tensor
    for kdiag = 1:Kf-1  # index of diagonal of ε tensor
        # For the input averaging, ∆l and ∆l′ are supplied to create min in order to create
        # a line integral averaging operator.  This is because the inverse of the length
        # factor matrix multiplied for symmetry to the right of the material parameter
        # matrix divides the two fields being averaged by different (= nonuniform) line
        # segments.  The ∆l factors multiplied inside create_minfo cancel the effect of this
        # multiplication with the nonuniform line segments.  (See my notes on Jul/18/2018 in
        # MaxwellFDM in Agenda.)
        Min = create_mean(isfwd_in, N, ∆l, ∆l′, isbloch, e⁻ⁱᵏᴸ, order_cmpfirst=order_cmpfirst)

        # Below, Min and Mout are block-diagonal, but param_matₖ is block-off-diagonal
        # (1 ≤ kdiag ≤ Kf-1).  See my bullet point entitled [Update (May/13/2018)] in RN -
        # Subpixel Smoothing.
        param_matₖ = create_param_matrix(paramKd, kdiag, N, order_cmpfirst=order_cmpfirst)
        param_mat += Mout * param_matₖ * Min
    end

    return param_mat
end

# About the meaning of kdiag
#
# Suppose material parameter tensor is Kf-by-Kf.  Different values of kdiag take different
# entries of the material parameter tensor and used to create a matrix.  For Kf = 3, here
# are the entries (indicated by X) taken for the three different values of kdiag.
#
# kdiag = 0:
# ⎡X O O⎤
# ⎢O X O⎥
# ⎣O O X⎦
#
# kdiag = 1:
# ⎡O X O⎤
# ⎢O O X⎥
# ⎣X O O⎦
#
# kdiag = 2 (= Kf-1):
# ⎡O O X⎤
# ⎢X O O⎥
# ⎣O X O⎦
#
# So, kdiag is the index counted from the main diagonal (kdiag = 0) along the superdiagonal
# direction.  See RN - Subpixel Smoothing > [Update (May/13/2018)].  Note that if the X is
# the vw-block, then it is constructed with the vw-component of the material parameter (e.g.,
# for ε, if X is the xy-block, then it is constructed with εxy).
function create_param_matrix(paramKd::AbsArrComplex{K₊₂},  # size of last two dimensions: Kf-by-Kf
                             kdiag::Integer,  # 0 ≤ kdiag ≤ Kf-1; index of diagonal of material parameter tensor to set (kdiag = 0: main diagonal)
                             N::SInt{K};  # size of grid
                             order_cmpfirst::Bool=true  # true to use Cartesian-component-major ordering for more tightly banded matrix
                             ) where {K,K₊₂}
    Kf = size(paramKd, K+1)  # field dimension
    @assert size(paramKd,K+2)==Kf

    # Note that paramKd's i, j, k indices run from 1 to N+1 rather than to N, so we should
    # not iterate those indices from 1 to end (= N+1).
    M = prod(N)  # number of voxels
    KfM = Kf * M
    I = VecInt(undef, KfM)
    J = VecInt(undef, KfM)
    V = VecComplex(undef, KfM)
    n = 0

    CI = CartesianIndices(N.data)
    LI = LinearIndices(N.data)
    for nv = 1:Kf  # row index of material parameter tensor
        istr, ioff = order_cmpfirst ? (Kf, nv-Kf) : (1, M*(nv-1))  # (row stride, row offset)
        nw = mod1(nv+kdiag, Kf)  # column index of material parameter tensor
        jstr, joff = order_cmpfirst ? (Kf, nw-Kf) : (1, M*(nw-1))  # (column stride, column offset)
        for ci = CI
            n += 1
            ind = LI[ci]  # linear index of Yee's cell

            I[n] = istr * ind + ioff
            J[n] = jstr * ind + joff
            V[n] = paramKd[ci,nv,nw]
        end
    end

    return sparse(I, J, V, KfM, KfM)
end
