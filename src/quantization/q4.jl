function make_qkx1_quants(nmax::Int, x::AbstractVector{Float32}, L::AbstractVector{UInt8}, ntry::Int)
    min_x = x[1]
    max_x = x[1]

    n = length(x)

    for i in 2:length(x)
        if x[i] < min_x
            min_x = x[i]
        end

        if x[i] > max_x
            max_x = x[i]
        end
    end

    if max_x == min_x
        for i in 1:n
            L[i] = 0
        end

        return 0f0, 0
    end

    if min_x > 0f0
        min_x = 0f0
    end

    iscale = nmax / (max_x - min_x)
    scale = inv(iscale)

    for _ in 1:ntry
        sumlx = 0f0
        suml2 = Int32(0)
        did_change = false

        for i in 1:n
            l = Base.unsafe_trunc(Int32, round(iscale*(x[i] - min_x)))
            l = max(Int32(0), min(Int32(nmax), l))

            if l != L[i]
                L[i] = l
                did_change = true
            end

            sumlx += (x[i] - min_x)*l
            suml2 += l*l
        end

        scale = sumlx/suml2
        sum = 0f0

        for i in 1:n
            sum += x[i] - scale*L[i]
        end

        min_x = sum/n

        if min_x > 0f0
            min_x = 0f0
        end

        iscale = inv(scale)

        if !did_change
            break
        end
    end

    return scale, -min_x
end

Base.@propagate_inbounds function get_scale_min_k4(j::Int, q::AbstractVector{UInt8})
    if j <= 4
        d = q[j] & UInt8(63)
        m = q[j + 4] & UInt8(63)
    else
        d = (q[j+4] & 0xF) | ((q[j-4] >> 6) << 4)
        m = (q[j+4] >>  4) | ((q[j-0] >> 6) << 4)
    end

    return d, m
end

function quantize!(y::Vector{block_q4_K}, x::Vector{Float32})
    k = length(x)
    @assert k % QK_K == 0
    nb = k ÷ QK_K

    L = zeros(UInt8, QK_K)
    mins = zeros(Float32, QK_K ÷ 32)
    scales = zeros(Float32, QK_K ÷ 32)

    for i in 1:nb
        max_scale = 0f0
        max_min = 0f0

        for j in 1:(QK_K÷32)
            scales[j], mins[j] = make_qkx1_quants(
                15,
                view(x, (QK_K*(i-1) + 32*(j-1) + 1):(QK_K*(i-1) + 32*j)),
                view(L, (32*(j-1) + 1):(32*j)),
                5,
            )

            scale = scales[j]
            if scale > max_scale
                max_scale = scale
            end

            min = mins[j]
            if min > max_min
                max_min = min
            end
        end

        inv_scale = max_scale > 0 ? 63f0/max_scale : 0f0
        inv_min   = max_min   > 0 ? 63f0/max_min   : 0f0

        yi_d = MutableField(Float16, y, i, :d)
        yi_dmin = MutableField(Float16, y, i, :dmin)
        yi_scales = MutableField(UInt8, y, i, :scales)
        yi_qs = MutableField(UInt8, y, i, :qs)

        for j in 1:(QK_K÷32)
            ls = Base.unsafe_trunc(UInt8, round(inv_scale*scales[j]))
            lm = Base.unsafe_trunc(UInt8, round(inv_min*mins[j]))
            ls = min(UInt8(63), ls)
            lm = min(UInt8(63), lm)

            if j <= 4
                yi_scales[j] = ls
                yi_scales[j+4] = lm
            else
                yi_scales[j+4] = (ls & 0xF) | ((lm & 0xF) << 4)
                yi_scales[j-4] |= ((ls >> 4) << 6)
                yi_scales[j-0] |= ((lm >> 4) << 6)
            end
        end

        yi_d[1] = Float16(max_scale/63f0)
        yi_dmin[1] = Float16(max_min/63f0)

        for j in 1:(QK_K÷32)
            sc, m = get_scale_min_k4(j, yi_scales)

            d = Float32(yi_d[1]) * sc

            if d == 0f0
                continue
            end

            dm = Float32(yi_dmin[1]) * m

            for ii in 1:32
                l = Base.unsafe_trunc(Int32, round((x[QK_K*(i-1) + 32*(j-1) + ii] + dm)/d))
                l = max(Int32(0), min(Int32(15), l))
                L[32*(j-1) + ii] = l
            end
        end

        for j in 1:(QK_K ÷ 64)
            for l in 1:32
                yi_qs[32*(j-1) + l] = L[64*(j-1) + l] | (L[64*(j-1) + 32 + l] << 4)
            end
        end
    end

    return y
end

function dequantize!(y::AbstractVector{Float32}, x::AbstractVector{block_q4_K})
    k = length(y)
    @assert k % QK_K == 0
    nb = k ÷ QK_K

    @inbounds for i in 1:nb
        d = Float32(MutableField(Float16, x, i, :d)[1])
        dmin = Float32(MutableField(Float16, x, i, :dmin)[1])
        scales = MutableField(UInt8, x, i, :scales)
        q = MutableField(UInt8, x, i, :qs)

        for j in 1:(QK_K÷64)
            sc, m = get_scale_min_k4(2*(j-1) + 1, scales)
            d1 = d * sc
            m1 = dmin * m

            sc, m = get_scale_min_k4(2*(j-1) + 2, scales)
            d2 = d * sc
            m2 = dmin * m

            @simd ivdep for l in 1:32
                y[QK_K*(i-1) + 64*(j-1) + l] = d1 * (q[32*(j-1) + l] & 0xF) - m1
            end

            @simd ivdep for l in 1:32
                y[QK_K*(i-1) + 64*(j-1) + 32 + l] = d2 * (q[32*(j-1) + l] >> 4) - m2
            end
        end
    end

    return y
end

function LinearAlgebra.dot(x::AbstractVector{block_q4_K}, y::AbstractVector{block_q8_K})
    @assert length(x) == length(y)
    nb = length(x)

    kmask1 = 0x3f3f3f3f
    kmask2 = 0x0f0f0f0f
    kmask3 = 0x03030303

    sums = ntuple(_ -> 0f0, Val(8))
    sumf = 0f0

    @inbounds for i in 1:nb
        q4 = MutableField(UInt8, x, i, :qs)
        q8 = MutableField(Int8, y, i, :qs)
        y_bsums = MutableField(Int16, y, i, :bsums)

        a_ = ntuple(@inline(j -> (
            ntuple(@inline(l -> reinterpret(Int8, q4[32*(j-1)+l] & 0xF)), Val(32)),
            ntuple(@inline(l -> reinterpret(Int8, q4[32*(j-1)+l] >> 4)), Val(32)),
        )), Val(QK_K÷64))

        a = @inline reinterpret(NTuple{256,Int8}, a_)

        utmp0, utmp1, utmp2 = @inline reinterpret(NTuple{3,UInt32}, x[i].scales)

        utmp3 = ((utmp2 >> 4) & kmask2) | (((utmp1 >> 6) & kmask3) << 4)
        uaux = utmp1 & kmask1
        utmp1 = (utmp2 & kmask2) | (((utmp0 >> 6) & kmask3) << 4)
        utmp2 = uaux
        utmp0 &= kmask1

        scales = @inline reinterpret(NTuple{8,UInt8}, (utmp0, utmp1))
        mins = @inline reinterpret(NTuple{8,UInt8}, (utmp2, utmp3))

        sumi = Int32(0)

        @simd ivdep for j in 1:(QK_K÷16)
            sumi += Int32(y_bsums[j]) * Int32(mins[(j-1)÷2+1])
        end

        aux32 = ntuple(_ -> Int32(0), Val(8))

        for j in 1:(QK_K÷32)
            scale = Int32(scales[j])

            aux32 = aux32 .+ scale .* ntuple(k -> @inbounds(Int32(q8[32*(j-1)+k])*Int32(a[32*(j-1)+k])), Val(8))
            aux32 = aux32 .+ scale .* ntuple(k -> @inbounds(Int32(q8[32*(j-1)+8+k])*Int32(a[32*(j-1)+8+k])), Val(8))
            aux32 = aux32 .+ scale .* ntuple(k -> @inbounds(Int32(q8[32*(j-1)+16+k])*Int32(a[32*(j-1)+16+k])), Val(8))
            aux32 = aux32 .+ scale .* ntuple(k -> @inbounds(Int32(q8[32*(j-1)+24+k])*Int32(a[32*(j-1)+24+k])), Val(8))
        end

        d = Float32(x[i].d) * y[i].d

        sums = sums .+ d .* aux32

        dmin = Float32(x[i].dmin) * y[i].d

        sumf -= dmin * sumi
    end

    sumf += sum(sums)

    return sumf
end
