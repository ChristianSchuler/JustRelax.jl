using ParallelStencil
@init_parallel_stencil(Threads, Float64, 2)

using Printf, LinearAlgebra, GeoParams, CellArrays
using JustRelax, JustRelax.JustRelax2D
import JustRelax.@cell
const backend_JR = CPUBackend # Options: CPUBackend, CUDABackend, AMDGPUBackend

using JustPIC, JustPIC._2D
# Threads is the default backend,
# to run on a CUDA GPU load CUDA.jl (i.e. "using CUDA") at the beginning of the script,
# and to run on an AMD GPU load AMDGPU.jl (i.e. "using AMDGPU") at the beginning of the script.
const backend = CPUBackend # Options: CPUBackend, CUDABackend, AMDGPUBackend

# x-length of the domain
const λ = 0.9142

# HELPER FUNCTIONS ---------------------------------------------------------------
# Initialize phases on the particles
function init_phases!(phases, particles)
    ni = size(phases)

    @parallel_indices (i, j) function init_phases!(phases, px, py, index)
        @inbounds for ip in JustRelax.cellaxes(phases)
            # quick escape
            JustRelax.@cell(index[ip, i, j]) == 0 && continue

            x = JustRelax.@cell px[ip, i, j]
            y = JustRelax.@cell py[ip, i, j]

            # plume - rectangular
            if y > 0.2 + 0.02 * cos(π * x / λ)
                JustRelax.@cell phases[ip, i, j] = 2.0
            else
                JustRelax.@cell phases[ip, i, j] = 1.0
            end
        end
        return nothing
    end

    @parallel (@idx ni) init_phases!(phases, particles.coords..., particles.index)
end
# END OF HELPER FUNCTIONS --------------------------------------------------------

# MAIN SCRIPT --------------------------------------------------------------------
function main2D(igg; ny=64, nx=64, figdir="model_figs")

    # Physical domain ------------------------------------
    ly           = 1            # domain length in y
    lx           = ly           # domain length in x
    ni           = nx, ny       # number of cells
    li           = lx, ly       # domain length in x- and y-
    di           = @. li / ni   # grid step in x- and -y
    origin       = 0.0, 0.0     # origin coordinates
    grid         = Geometry(ni, li; origin = origin)
    (; xci, xvi) = grid # nodes at the center and vertices of the cells
    dt           = 1e-10

    # Physical properties using GeoParams ----------------
    rheology = (
        # Low density phase
        SetMaterialParams(;
            Phase             = 1,
            Density           = ConstantDensity(; ρ = 1),
            Gravity           = ConstantGravity(; g = 1),
            CompositeRheology = CompositeRheology((LinearViscous(; η = 1e0),)),

        ),
        # High density phase
        SetMaterialParams(;
            Density           = ConstantDensity(; ρ = 2),
            Gravity           = ConstantGravity(; g = 1),
            CompositeRheology = CompositeRheology((LinearViscous(;η = 1e0),)),
        ),
    )

    # Initialize particles -------------------------------
    nxcell, max_p, min_p = 40, 80, 20
    particles            = init_particles(
        backend, nxcell, max_p, min_p, xvi..., di..., nx, ny
    )
    # velocity grids
    grid_vx, grid_vy     = velocity_grids(xci, xvi, di)
    # temperature
    pPhases,             = init_cell_arrays(particles, Val(1))
    particle_args        = (pPhases, )
    phase_ratios         = PhaseRatio(backend_JR, ni, length(rheology))
    init_phases!(pPhases, particles)
    phase_ratios_center!(phase_ratios, particles, grid, pPhases)

    # STOKES ---------------------------------------------
    # Allocate arrays needed for every Stokes problem
    stokes               = StokesArrays(backend_JR, ni)
    pt_stokes            = PTStokesCoeffs(li, di; r=1e0, ϵ=1e-8,  CFL = 1 / √2.1)

    # Buoyancy forces
    ρg                   = @zeros(ni...), @zeros(ni...)
    args                 = (; T = @zeros(ni...), P = stokes.P, dt = dt)
    compute_ρg!(ρg[2], phase_ratios, rheology, args)

    # Rheology
    compute_viscosity!(stokes, phase_ratios, args, rheology, (-Inf, Inf))

    # Boundary conditions
    flow_bcs             = FlowBoundaryConditions(;
        free_slip = (left =  true, right =  true, top = false, bot = false),
        no_slip   = (left = false, right = false, top =  true, bot =  true),
    )
    flow_bcs!(stokes, flow_bcs)
    update_halo!(stokes.V.Vx, stokes.V.Vy)

    # IO ----- -------------------------------------------
    # if it does not exist, make folder where figures are stored
    !isdir(figdir) && mkpath(figdir)
    # ----------------------------------------------------

    # Buffer arrays to compute velocity rms
    Vx_v  = @zeros(ni.+1...)
    Vy_v  = @zeros(ni.+1...)

    # Time loop
    t, it = 0.0, 0
    tmax  = 2e3
    Urms  = Float64[]
    trms  = Float64[]
    sizehint!(Urms, 100000)
    sizehint!(trms, 100000)

    while t < tmax

        # Update buoyancy
        compute_ρg!(ρg[2], phase_ratios, rheology, args)
        # ------------------------------

        # Stokes solver ----------------
        solve!(
            stokes,
            pt_stokes,
            di,
            flow_bcs,
            ρg,
            phase_ratios,
            rheology,
            args,
            dt,
            igg;
            kwargs = (
                iterMax          = 10e3,
                nout             = 50,
                viscosity_cutoff = (-Inf, Inf)
            )
        )
        dt = compute_dt(stokes, di) / 10
        # ------------------------------

        # Compute U rms ---------------
        Urms_it = let
            JustRelax.velocity2vertex!(Vx_v, Vy_v, stokes.V.Vx, stokes.V.Vy; ghost_nodes=true)
            @. Vx_v .= hypot.(Vx_v, Vy_v) # we reuse Vx_v to store the velocity magnitude
            sum(Vx_v.^2) * prod(di) |> sqrt
        end
        push!(Urms, Urms_it)
        push!(trms, t)
        # ------------------------------

        # advect particles in space
        advection!(particles, RungeKutta2(), @velocity(stokes), (grid_vx, grid_vy), dt)
        # # advect particles in memory
        move_particles!(particles, xvi, particle_args)
        # inject && break
        inject_particles_phase!(particles, pPhases, (), (), xvi)
        # update phase ratios
        phase_ratios_center!(phase_ratios, particles, grid, pPhases)

        @show it += 1
        t        += dt

        # Plotting ---------------------
        if it == 1 || rem(it, 1000) == 0 || t >= tmax
            fig = Figure(size = (1000, 1000), title = "t = $t")
            ax1 = Axis(fig[1,1], aspect = 1/λ, title = "t=$t")
            heatmap!(ax1, xvi[1], xvi[2], Array(ρg[2]), colormap = :oleron)
            save( joinpath(figdir, "$(it).png"), fig)
            fig
        end

    end

    # df = DataFrame(t=trms, Urms=Urms)
    # CSV.write(joinpath(figdir, "Urms.csv"), df)

    return nothing
end

figdir = "VanKeken"
n      = 128 + 2
nx     = n - 2
ny     = n - 2
igg  = if !(JustRelax.MPI.Initialized())
    IGG(init_global_grid(nx, ny, 1; init_MPI = true)...)
else
    igg
end
main2D(igg; figdir = figdir, nx = nx, ny = ny);
