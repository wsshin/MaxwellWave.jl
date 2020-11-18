# To-dos:
#
# - How do we handle TF/SF?  Need a capability to do subpixel smoothing only inside some
# region.
#
# - A symmetry boundary puts the mirror image of the boundary-touching object in the space
# behind the boundary.  When this happens, not only the shape but also the material of the
# object must be flipped with respect to the symmetry boundary.  Such material flip is
# currently unsupported: only the Bloch boundary condition is valid for the boundary
# touching anisotropic materials.

export smooth_param!

# Given a vector `v` of comparable objects and vector `ind` of indices that sort `v`, return
# the number `c` of different objects in `v` and the index `nₑ` of `ind` where the last new
# object occurs (i.e., v[ind[nₑ]] is the last new object).
#
# If v is uniform, nₑ = length(v) + 1 (i.e., it is out of bound).
#
# For efficiency, this function assumes `v` is a vector of objects assigned to a voxel, i.e.,
# length(v) = 8.
@inline function countdiff(ind::MArray{TP,<:Integer,K,Zᴷ}, v::MArray{TP,<:Real,K,Zᴷ}) where {TP,K,Zᴷ}
    # Zᴷ = number of entries in MArray
    c, nₑ = 1, Zᴷ+1
    @simd for n = 2:Zᴷ
        @inbounds v[ind[n-1]] ≠ v[ind[n]] && (c += 1; nₑ = n)
    end
    return c, nₑ  # c: number of changes in v; nₑ: last n where v[ind[n]] changed
end

# vectors from voxel corners to the voxel center
nout_vxl(::Val{3}) = (SVector(1.,1.,1.), SVector(-1.,1.,1.), SVector(1.,-1.,1.), SVector(-1.,-1.,1.),
                      SVector(1.,1.,-1.), SVector(-1.,1.,-1.), SVector(1.,-1.,-1.), SVector(-1.,-1.,-1.))
nout_vxl(::Val{2}) = (SVector(1.,1.), SVector(-1.,1.), SVector(1.,-1.), SVector(-1.,-1.))
nout_vxl(::Val{1}) = (SVector(1.), SVector(-1.))

# Determine if the field subspace is orthogonal to the shape subspace.
#
# The shape and field subspaces are the subspaces of the 3D space where the shapes and
# fields lie.  In standard 3D problems, both subspaces are 3D.  However there are other
# cases as well: for example, in 2D TM problems, the shapes are on the xy-plane (2D space),
# but the E-fields are along the z-direction (1D space).
#
# For the shape and field subspace dimensions K and Kf, orthogonal subspaces can occur only
# when K + Kf ≤ 3, because if two subspaces are orthogonal to each other and K + Kf > 3, we
# can choose K + Kf linearly independent vectors in the direct sum of the two subspaces,
# which is impossible as the direct sum should still be a subspace of the 3D space.
#
# Considering the above, there are only a few combinations of K and Kf that allow orthogonal
# subspaces: (K,Kf) = (2,1), (1,1), (1,2).
# - (K,Kf) = (2,1).  This happens in 2D TE or TM problems.  The shape subspace is the 2D xy-
# plane, but the magnetic (electric) field subspace in TE (TM) problems is the 1D z-axis.
# - (K,Kf) = (1,1).  This happens in the 1D TEM problems with isotropic materials.  The
# shape subspace is the 1D z-axis, but the E- and H-field spaces are the 1D x- and y-axes.
# - (K,Kf) = (1,2).  This happens in the 1D TEM problem with anisotropic materials.
#
# Note that we can always solve problems as if they are 3D problems.  So, the consideration
# of the cases with K, Kf ≠ 3 occurs only when we can build special equations with reduced
# number of degrees of freedom, like in the TE, TM, TEM equations.  In such cases, we find
# that the two subspaces are always orthogonal if K ≠ Kf.  In fact, smooth_param!() is
# written such that the Kottke's subpixel smoothing algorithm that decomposes the field into
# the components tangential and normal to the shape surface is applied only when the shape
# and field subspaces coincide.  (This makes sense, because the inner product between the
# field and the direction normal that needs to be performed to decompose the field into such
# tangential and normal components is defined only when the field and the direction normal
# are in the same vector space.)  Therefore, if we want to apply Kottke's subpixel smoothing
# algorithm that depends on the surface normal direction, we have to construct the problem
# such that K = Kf (but the converse is not true: K = Kf does not imply the use of Kottke's
# subpixel smoothing algorithm that depends on the surface normal direction; in other words,
# the case with K = Kf can still use the subpixel smoothing algorithm that assumes the
# orthogonality between the shape and field subspace, such that the field is always
# tangential to the shape surface.)
#
# The contraposition of the above statement is that if K ≠ Kf, then Kottke's subpixel
# smoothing algorithm that does NOT depend on the direction normal is applied.  This
# subpixel smoothing algorithm assumes that the field subspace is orthogonal to the shape
# subspace, such that the field has only the tangential component to the surface.
# Therefore, if we pass K ≠ Kf to smooth_param!(), we should make sure that the field
# subspace is orthogonal to the shape subspace.  Note that this does not exclude the
# possibility of K ≠ Kf while the two subspaces are nonorthogonal; it just means that we
# must formulate the problem differently in such cases by, e.g., decomposing the equations,
# in order to use smooth_param!().
#
# As noted earlier, K = Kf can stil include cases where the shape and field subspaces are
# orthogonal.  Because K + Kf = 2K should be ≤ 3 in+ such cases, we conclude that K = Kf = 1
# is the only case where the two subspaces could be orthogonal while K = Kf.  In fact, when
# K = Kf, we will assume that the two subspaces are orthogonal, because the problems with 1D
# slabs and the field along the slab thickness direction are not interesting from the EM
# wave propagation perspectives.
isfield_ortho_shape(Kf, K) = Kf≠K || Kf==1

# Overall smoothing algorithm
#
# Below, obj, pind, oind refers to an Object{3} instance, parameter index (integer value) that
# distinguishes different material parameters, and oind that distinguishes different objects.
#
# - Assign oind, pind, shape to arrays object-by-object (see assignment.jl).
#     - Currently, we assign only oind (in oindKd′), and pind and shape are retrieved from oind by oind2shp and oind2pind.
#     - For the locations of grid points to assign the objects to, use τlcmp (lcmp created considering BC).
# - Using oind and pind, determine voxels to perform subpixel smoothing.
# - Inside each voxel, figure out the foreground object with which subpixel smoothing is performed.
#     - Iterating voxel corners, find the object that is put latest.  That object is the foreground object.
#     - Complication occurs when the voxel corner assigned with the foreground object is outside the domain boundary.
#         - In that case, to calculate nout and rvol properly, we have to move the voxel center.  (This is effectively the same as moving the foreground object.)
#             - If the corner is outside the periodic boundary, translate the voxel center before calling surfpt_nearby (using ∆fg).
#             - If the corner is outside the symmetry boundary, zero the nout component normal to the boundary (using σvxl).
#             - ∆fg and σvxl can be obtained simply by looking at the indices and BC.

# Below, the primed quantities are for voxel corner quantities rather than voxel center
# quantities.  Compare this with the usage of the prime in assignment.el that indicates
# complementary material (i.e., magnetic for electric).
function smooth_param!(paramKd::AbsArrComplex{K₊₂},  # parameter array to smooth at voxel centers
                       oindKd′::NTuple{Kf⏐₁,AbsArr{ObjInd,K}},  # object index array at voxel corners; does not change
                       oind2shp::AbsVec{Shape{K,K²}},  # input map from oind to shape
                       oind2pind::AbsVec{ParamInd},  # input map from oind to pind
                       pind2matprm::AbsVec{SSComplex{Kf,Kf²}},  # map from pind to electric (magnetic) material parameters; Kf² = Kf^2
                       gt₀::SVector{K,GridType},  # grid type of voxel corners; generated by ft2gt.(ft, boundft)
                       l::Tuple2{NTuple{K,AbsVecReal}},  # location of field components; exclude ghost points (length(l[PRIM][k]) = N[k])
                       l′::Tuple2{NTuple{K,AbsVecReal}},  # location of voxel corners without transformation by boundary conditions; include ghost points (length(l′[PRIM][k]) = N[k]+1)
                       σ::Tuple2{NTuple{K,AbsVecBool}},  # false if on symmetry boundary; exclude ghost points (length(σ[PRIM][k]) = N[k])
                       ∆τ′::Tuple2{NTuple{K,AbsVecReal}},  # amount of shift by Bloch boundary conditions; include ghost points (length(∆τ′[PRIM][k]) = N[k]+1)
                       isfield˔shp::Bool=isfield_ortho_shape(Kf,K)  # true if spaces where field and shapes are defined are orthogonal complement of each other; false if they are the same
                       ) where {K,Kf,K²,Kf²,K₊₂,Kf⏐₁}
    @assert K²==K^2 && Kf²==Kf^2 && K₊₂==K+2 && (Kf⏐₁==Kf || Kf⏐₁==1)
    @assert size(paramKd,K+1)==size(paramKd,K+2)==Kf

    ci_1 = CartesianIndex(ntuple(x->1, Val(K)))
    for nw = 1:Kf⏐₁
        # Set the grid types of the x-, y-, z-locations of Fw.
        gt_cmp = Kf⏐₁==1 ? gt₀ : gt_w(nw, gt₀)

        # Set the grid types of the voxel corners surroundnig Fw.
        gt_cmp′ = alter.(gt_cmp)

        # Choose various vectors for Fw (which is at the centers of the voxel defined by the
        # voxel corners below).
        lcmp = t_ind(l, gt_cmp)
        σcmp = t_ind(σ, gt_cmp)

        # Choose various arrays and vectors for voxel corners.
        lcmp′ = t_ind(l′, gt_cmp′)
        ∆τcmp′ = t_ind(∆τ′, gt_cmp′)

        oind_cmp′ = oindKd′[nw]

        ind_c = MArray{Tuple{ntuple(x->2,Val(K))...},Int}(undef)  # corner indices inside voxel
        pind_vxl′ = similar(ind_c)  # material parameter indices inside voxel
        oind_vxl′ = similar(ind_c)  # object indices inside voxel

        # Set various arrays for the current component.
        CI = CartesianIndices(length.(lcmp))
        for ci_cmp = CI
            ci_vxl′ = (ci_cmp, ci_cmp + ci_1)  # Tuple2{SInt{3}}

            if !is_vxl_uniform!(oind_vxl′, pind_vxl′, ci_vxl′, oind_cmp′, oind2shp, oind2pind)
                # Note that pind_vxl′ is initialized at this point.
                sort_ind!(ind_c, pind_vxl′)  # pind_vxl′[ind_c[n]] ≤ pind_vxl′[ind_c[n+1]]
                Nprm_vxl, n_diffp = countdiff(ind_c, pind_vxl′)  # n_diffp: last n where pind_vxl′[ind_c[n]] changed

                if Nprm_vxl ≥ 2
                    if Nprm_vxl == 2
                        # Attempt to apply Kottke's subpixel smoothing algorithm.
                        prm_vxl = smooth_param_vxl(ci_vxl′, ind_c, n_diffp, pind_vxl′, oind_vxl′,
                                                   oind_cmp′, oind2shp, oind2pind, pind2matprm,
                                                   lcmp, lcmp′, σcmp, ∆τcmp′, isfield˔shp)
                    else  # Nprm_vxl ≥ 3
                        # Give up Kottke's subpixel smoothing and take simple averaging.
                        prm_vxl = ft==EE ? amean_param(ci_vxl′, oind_cmp′, oind2pind, pind2matprm)::SSComplex{Kf,Kf²} :
                                           hmean_param(ci_vxl′, oind_cmp′, oind2pind, pind2matprm)::SSComplex{Kf,Kf²}
                    end  # if Nprm_vxl == 2

                    # Below, we have four combinations depending on the values of Kf⏐₁ and Kf:
                    # Kf⏐₁ is either ==Kf or ==1, and Kf is either ≥2 or ==1.
                    #
                    # The case of Kf⏐₁ == Kf covers Kf≥2 and Kf==1.  When Kf==1, the case
                    # corresponds to Kf⏐₁==1 and Kf==1.  Therefore, the "if" case Kf⏐₁ == Kf
                    # covers the two combinations:
                    # - Kf⏐₁==Kf and Kf≥2,
                    # - Kf⏐₁==1 and Kf==1.
                    #
                    # Therefore, the "else" case should cover the remaining two combinations:
                    # - Kf⏐₁==Kf && Kf==1,
                    # - Kf⏐₁==1 && Kf≥2.
                    # However, the first combination is equivalent to Kf⏐₁==1 && Kf==1, which
                    # was already covered in the "if" case.  Therefore, the "else" case
                    # deals with only the case of Kf⏐₁==1 && Kf≥2.
                    if Kf⏐₁ == Kf  # Kf⏐₁==Kf && Kf≥2, or Kf⏐₁==1 && Kf==1
                        # Overwrite the (nw,nw)-diagonal entry of paramKd.
                        @inbounds paramKd[ci_cmp,nw,nw] = prm_vxl[nw,nw]
                    else  # Kf⏐₁==1 && Kf≥2
                        # Overwrite the off-diagonal entires of paramKd.
                        # Below the main diagonal.
                        for c = 1:Kf, r = c+1:Kf  # column- and row-indices
                            @inbounds paramKd[ci_cmp,r,c] = prm_vxl[r,c]
                        end

                        # Above the main diagonal.
                        for c = 2:Kf, r = 1:c-1  # column- and row-indices
                            @inbounds paramKd[ci_cmp,r,c] = prm_vxl[r,c]
                        end
                    end  # if Kf⏐₁ == 1
                end  # if Nprm_vxl ≥ 2
                # If Nprm_vxl = 1, the voxel is filled with the same material, and there is
                # no need for subpixel smoothing.
            end  # if !is_vxl_uniform!
        end  # for ci_cmp = CI
    end  # for nw = 1:Kf+1

    return nothing
end

function is_vxl_uniform!(oind_vxl′::MArray{TP,Int,K,Zᴷ},  # scratch vector to store object indices inside voxel; TP = Tuple{2,...,2}, Zᴷ = 2^K
                         pind_vxl′::MArray{TP,Int,K,Zᴷ},  # scratch vector to store material parameter indices inside voxel; TP = Tuple{2,...,2}, Zᴷ = 2^K
                         ci_vxl′::Tuple2{CartesianIndex{K}},
                         oind_cmp′::AbsArr{ObjInd,K},  # object index array; does not change
                         oind2shp::AbsVec{Shape{K,K²}},  # input map from oind to shape
                         oind2pind::AbsVec{ParamInd}  # input map from oind to pind
                         ) where {K,K²,TP,Zᴷ}
    # Retrieve the elements assigned to voxel corners from 3D arrays.
    #
    # Unlike the rest of the code that is performed only where subpixel smoothing is
    # performed, the following for loop is performed at all grid points.  Therefore, the
    # number of assignments to perform in the following for loop can easily reach
    # several millions even for a simple 3D problem.  Simple assignment can
    # be surprisingly time-consuming when peformed such a large number of times.  The
    # use of @inbounds helps reducing assignment time significantly.
    nc = 0
    for ci = ci_vxl′[1]:ci_vxl′[2]
        nc += 1
        @inbounds oind_vxl′[nc] = oind_cmp′[ci]
    end

    is_vxl_uniform = isuniform(oind_vxl′)

    # Even if the voxel is filled with multiple objects, those objects could be made of
    # the same material.  Then, the voxel is still filled with uniform material
    if !is_vxl_uniform
        for nc = 1:Zᴷ
            @inbounds pind_vxl′[nc] = oind2pind[oind_vxl′[nc]]
        end

        # We could use Nprm_vxl calculated below instead of is_vxl_uniform: if
        # Nprm_vxl = 1, then is_vxl_uniform = true.  However, calculating Nprm_vxl
        # requires calling sort8! and countdiff, which are costly when called for all
        # voxels.  Therefore, by using is_vxl_uniform, we avoid calling those functions
        # when unnecessary.
        @inbounds is_vxl_uniform = isuniform(pind_vxl′)
    end

    # Note that when is_vxl_uniform = false at this point, pind_vxl′ is initialized.
    return is_vxl_uniform
end



# Calculate prm_vxl (averaged material parameter for Fw inside a voxel) when the voxel is
# composed of two material parameters (Nprm_vxl = 2).  This includes cases where the voxel
# is composed of two material parameters but of ≥3 shape (i.e., ≥2 shapes in the voxel have
# the same material).
#
# Below, XXX_cmp has size N, whereas XXX_cmp′ has size N+1 (and corresponds to voxel corners).
# Variable names ending with vxl store quantities within a voxel.  Primed names store values
# at voxel corners; nonprimed names store values representing a voxel.
function smooth_param_vxl(ci_vxl′::Tuple2{CartesianIndex{K}},
                          ind_c::MArray{TP,Int,K,Zᴷ},  # scratch vector to store corner indices inside voxel; TP = Tuple{2,...,2}, Zᴷ = 2^K
                          n_diffp::Int,  # last n where pind_vxl′[ind_c[n]] changed
                          pind_vxl′::MArray{TP,Int,K,Zᴷ},  # scratch vector to store material parameter indices inside voxel; TP = Tuple{2,...,2}, Zᴷ = 2^K
                          oind_vxl′::MArray{TP,Int,K,Zᴷ},  # scratch vector to store object indices inside voxel; TP = Tuple{2,...,2}, Zᴷ = 2^K
                          oind_cmp′::AbsArr{ObjInd,K},  # object index array; does not change
                          oind2shp::AbsVec{Shape{K,K²}},  # input map from oind to shape
                          oind2pind::AbsVec{ParamInd},  # input map from oind to pind
                          pind2matprm::AbsVec{SSComplex{Kf,Kf²}},  # map from pind to electric (magnetic) material parameters; Kf² = Kf^2
                          lcmp::NTuple{K,AbsVecReal},  # location of field components
                          lcmp′::NTuple{K,AbsVecReal},  # location of voxel corners without transformation by boundary conditions
                          σcmp::NTuple{K,AbsVecBool},  # false if on symmetry boundary
                          ∆τcmp′::NTuple{K,AbsVecReal},  # amount of shift into domain by Bloch boundary conditions
                          isfield˔shp::Bool=false  # true if spaces where material parameters and shapes are defined are orthogonal complement of each other; false if they are the same
                          ) where {K,Kf,K²,Kf²,TP,Zᴷ}
        # First, attempt to apply Kottke's subpixel smoothing algorithm.
        nout = @SVector zeros(K)
        rvol = 0.0

        with2objs = true  # will be updated, because there could be ≥3 objects in voxel even if Nprm_vxl = 2
        @inbounds ind_c1, ind_c2 = ind_c[Zᴷ], ind_c[1]::Int  # indices of corners of two different material parameters
        @inbounds oind_c1, oind_c2 = oind_vxl′[ind_c1], oind_vxl′[ind_c2]

        # The corners ind_c[n_diffp:8] are occupied with one material parameter because
        # ind_c is sorted for pind_vxl′.  However, those corners can still be occupied with
        # ≥2 objects.  In that case, the voxel is composed of ≥3 objects.
        #
        # Note that not having two objects inside the voxel can logically mean having either
        # one object or ≥3 objects, but because Nprm_vxl ≥ 2, with2objs = false only means
        # having ≥3 objects inside the voxel.
        for nc = Zᴷ-1:-1:n_diffp  # n = 2^K-1 corresponds to oind_c1 and is omitted
            @inbounds (with2objs = oind_vxl′[ind_c[nc]]==oind_c1) || break
        end

        # At this point, with2objs = false means the corners ind_c[n_diffp:8] are composed
        # of ≥2 objects.  Then, we already know the voxel has ≥3 objects because the corners
        # ind_c[1:n_diffp-1] have different materials than the corners ind_c[n_diffp:8]
        # because Nprm_vxl = 2 and therefore have a different object than those occupying
        # the corners ind_c[n_diffp:8].  Hence, if with2objs = false at this point, we don't
        # have to test further if the voxel has ≥3 objects: it already has.
        if with2objs  # single object for corners ind_c[n_diffp:8]
            # The corners ind_c[1:n_diffp-1] are occupied with one material parameter
            # because ind_c is sorted for pind_vxl′, but those corners can still be occupied
            # with more than one object.  In that case, the voxel is composed of more than
            # two objects.
            for nc = 2:n_diffp-1  # n = 1 corresponds oind_c2 and is omitted
                @inbounds (with2objs = oind_vxl′[ind_c[nc]]==oind_c2) || break
            end
        end

        # Find which of ind_c1 and ind_c2 is the index of the corner occupied by the
        # foreground object.
        #
        # When multiple objects have the same object index (because they are essentially the
        # same object across a periodic boundary), it doesn't matter which object to choose
        # as the foreground (or background) object, we translate points properly across the
        # domain (by ∆fg below) in order to evaluate the surface normal direction on the
        # correct object.  (At least that is the intention, but this needs to be tested
        # after assigning the same object index is actually implemented.)
        if oind_c1 > oind_c2  # ind_c1 is foreground corner
            ind_fg = ind_c1
            oind_fg, oind_bg = oind_c1, oind_c2
        else  # ind_c2 is foreground corner
            @assert oind_c1≠oind_c2
            ind_fg = ind_c2
            oind_fg, oind_bg = oind_c2, oind_c1
        end
        @inbounds shp_fg, shp_bg = oind2shp[oind_fg], oind2shp[oind_bg]
        @inbounds prm_fg, prm_bg = pind2matprm[oind2pind[oind_fg]], pind2matprm[oind2pind[oind_bg]]

        # Find
        # - nout (outward normal of the foreground object), and
        # - rvol (volume fraction of the foreground object inside the voxel).
        ci_cmp = ci_vxl′[1]  # CartesianIndex{K}
        σvxl = t_ind(σcmp, ci_cmp)
        if !with2objs  # two material parameters but more than two objects in voxel
            # In this case, the interface between two materials is not defined by the
            # surface of a single object, so we estimate nout simply from the locations of
            # the corners occupied by the two materials.
            nout, rvol = kottke_input_simple(ind_c, n_diffp)::Tuple{SFloat{K},Float}
        else  # two objects
            # When Nprm_vxl == Nobj_vxl == 2, different material parameters must correspond
            # to different objects.
            x₀ = t_ind(lcmp, ci_cmp)  # SFloat{3}: location of center of smoothing voxel
            @inbounds lvxl′ = (t_ind(lcmp′,ci_vxl′[1]), t_ind(lcmp′,ci_vxl′[2]))

            @inbounds ci_fg = CartesianIndices(ntuple(x->2,Val(K)))[ind_fg]  # subscritpt of corner ind_fg
            ci_1 = CartesianIndex(ntuple(x->1, Val(K)))
            ∆fg = t_ind(∆τcmp′, ci_cmp + ci_fg - ci_1)  # SFloat{3}; nonzero if corner ind_fg is outside periodic boundary

            # See "Overall smoothing algorithm" above.
            nout, rvol = kottke_input_accurate(x₀, σvxl, lvxl′, ∆fg, shp_fg, shp_bg)::Tuple{SFloat{K},Float}
        end  # if !with2objs

        if iszero(nout)
            # Give up Kottke's subpixel smoothing and take simple averaging.
            prm_vxl = ft==EE ? amean_param(obj_cmp′, ci_vxl′, ft)::SSComplex{Kf,Kf²} :
                               hmean_param(obj_cmp′, ci_vxl′, ft)::SSComplex{Kf,Kf²}
        else
            # Perform Kottke's subpixel smoothing (defined in material.jl).
            prm_vxl = isfield˔shp ? kottke_avg_param(prm_fg, prm_bg, rvol) :  # field is always parallel to shape boundaries
                                    kottke_avg_param(prm_fg, prm_bg, nout, rvol)
        end

    return prm_vxl
end

function kottke_input_simple(ind_c::MArray{TP,Int,K,Zᴷ}, n_diffp::Integer) where {TP,K,Zᴷ}
    nout = @SVector zeros(K)  # nout for param_fg
    for n = n_diffp:Zᴷ  # n = Zᴷ corresponds ind_c[Zᴷ] used for param_fg
        @inbounds nout += nout_vxl(Val(K))[ind_c[n]]
    end
    rvol = (Zᴷ+1-n_diffp) / Zᴷ

    return nout, rvol
end


function kottke_input_accurate(x₀::SFloat{K}, σvxl::SBool{K}, lvxl′::Tuple2{SFloat{K}}, ∆fg::SFloat{K},
                               shp_fg::Shape{K,K²}, shp_bg::Shape{K,K²}) where {K,K²}
    r₀, nout = surfpt_nearby(x₀ + ∆fg, shp_fg)
    r₀ -= ∆fg
    nout = σvxl .* nout  # if voxel is across symmetry boundary plane, project nout to plane

    rvol = 0.0  # dummy value
    if !iszero(nout)
        rvol = volfrac(lvxl′, nout, r₀)
    end

    return nout, rvol
end

function amean_param(ci_vxl′::Tuple2{CartesianIndex{K}},
                     oind_cmp′::AbsArr{ObjInd,K},  # object index array; does not change
                     oind2pind::AbsVec{ParamInd},  # input map from oind to pind
                     pind2matprm::AbsVec{SSComplex{Kf,Kf²}}  # map from pind to electric (magnetic) material parameters; Kf² = Kf^2
                     ) where {K,Kf,Kf²}
    p = SSComplex{Kf,Kf²}(ntuple(x->0, Val(Kf²)))
    for ci = ci_vxl′[1]:ci_vxl′[2]
        @inbounds pc = pind2matprm[oind2pind[oind_cmp′[ci]]]
        p += pc
    end
    return p / 2^K
end

function hmean_param(ci_vxl′::Tuple2{CartesianIndex{K}},
                     oind_cmp′::AbsArr{ObjInd,K},  # object index array; does not change
                     oind2pind::AbsVec{ParamInd},  # input map from oind to pind
                     pind2matprm::AbsVec{SSComplex{Kf,Kf²}}  # map from pind to electric (magnetic) material parameters; Kf² = Kf^2
                     ) where {K,Kf,Kf²}
    p = SSComplex{Kf,Kf²}(ntuple(x->0, Val(Kf²)))
    for ci = ci_vxl′[1]:ci_vxl′[2]
        @inbounds pc = pind2matprm[oind2pind[oind_cmp′[ci]]]
        p += inv(pc)
    end
    return inv(p / 2^K)
end
