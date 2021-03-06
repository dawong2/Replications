!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: step_lf_global
!
!  DESCRIPTION:
!   Computes one (hydro) timestep
!
!   Change this subroutine to change the timestepping algorithm
!
!   This version uses a Velocity Verlet (leapfrog) integrator with
!   substepping (operator splitting) of external/sink particle forces,
!   following the Reversible RESPA algorithm of Tuckerman et al. 1992
!
!  REFERENCES:
!     Verlet (1967), Phys. Rev. 159, 98-103
!     Tuckerman, Berne & Martyna (1992), J. Chem. Phys. 97, 1990-2001
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS: None
!
!  DEPENDENCIES: chem, deriv, dim, eos, externalforces, io, io_summary,
!    mpiutils, options, part, ptmass, timestep, timestep_ind, timestep_sts
!+
!--------------------------------------------------------------------------
module step_lf_global
 use dim, only:maxp,maxvxyzu,maxBevol
 implicit none
 character(len=80), parameter, public :: &  ! module version
    modid="$Id$"

 real,            private :: vpred(maxvxyzu,maxp),dustpred(maxp)
 real(kind=4),    private :: Bpred(maxBevol,maxp)

contains

!------------------------------------------------------------
!+
!  initialisation routine necessary for individual timesteps
!+
!------------------------------------------------------------
subroutine init_step(npart,time,dtmax)
#ifdef IND_TIMESTEPS
 use timestep_ind, only:get_dt
 use part,         only:ibin,twas
#endif
 integer, intent(in) :: npart
 real,    intent(in) :: time,dtmax
#ifdef IND_TIMESTEPS
 integer :: i
!
! twas is set so that at start of step we predict
! forwards to half of current timestep
!
 !$omp parallel do schedule(static) private(i)
 do i=1,npart
    twas(i) = time + 0.5*get_dt(dtmax,ibin(i))
 enddo
#endif

end subroutine init_step

!------------------------------------------------------------
!+
!  main timestepping routine
!+
!------------------------------------------------------------
subroutine step(npart,nactive,t,dtsph,dtextforce,dtnew)
 use dim,            only:maxp,ndivcurlv,maxvxyzu,maxptmass,maxalpha,use_dustfrac,nalpha,h2chemistry
 use io,             only:iprint,fatal,iverbose,id,master,warning
 use options,        only:damp,tolv,iexternalforce,icooling
 use part,           only:xyzh,vxyzu,fxyzu,fext,divcurlv,divcurlB,Bevol,dBevol, &
                          isdead_or_accreted,rhoh,dhdrho,&
                          iphase,iamtype,massoftype,maxphase,igas,mhd,maxBevol,&
                          switches_done_in_derivs,iboundary,get_ntypes,npartoftype,&
                          dustfrac,dustevol,ddustfrac,alphaind,maxvecp,nptmass
 use eos,            only:get_spsound
 use options,        only:avdecayconst,alpha,ieos,alphamax
 use deriv,          only:derivs
 use timestep,       only:dterr,bignumber
 use mpiutils,       only:reduceall_mpi
 use part,           only:nptmass,xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass
 use io_summary,     only:summary_printout,summary_variable,iosumtvi
#ifdef IND_TIMESTEPS
 use timestep,       only:dtmax,dtmax_rat,dtdiff,mod_dtmax_in_step
 use timestep_ind,   only:get_dt,nbinmax,decrease_dtmax
 use timestep_sts,   only:sts_get_hdti,sts_get_dtau_next,use_sts,ibinsts,sts_it_n
 use part,           only:ibin,ibinold,twas,iactive
#endif
 integer, intent(inout) :: npart
 integer, intent(in)    :: nactive
 real,    intent(in)    :: t,dtsph
 real,    intent(inout) :: dtextforce
 real,    intent(out)   :: dtnew
 integer            :: i,its,np,ntypes,itype
 real               :: timei,erri,errmax,v2i,errmaxmean
 real               :: vxi,vyi,vzi,eni,vxoldi,vyoldi,vzoldi,hdtsph,pmassi
 real               :: alphaloci,divvdti,source,tdecay1,hi,rhoi,ddenom,spsoundi
 real               :: v2mean,hdti
#ifdef IND_TIMESTEPS
 real               :: dtsph_next,dtmaxold
#endif
 integer, parameter :: maxits = 30
 logical            :: converged,store_itype
!
! set initial quantities
!
 timei  = t
 hdtsph = 0.5*dtsph
 dterr  = bignumber

!--------------------------------------
! velocity predictor step, using dtsph
!--------------------------------------
 itype   = igas
 ntypes  = get_ntypes(npartoftype)
 pmassi  = massoftype(itype)
 store_itype = (maxphase==maxp .and. ntypes > 1)

 !$omp parallel do default(none) &
 !$omp shared(npart,xyzh,vxyzu,fxyzu,iphase,hdtsph,store_itype) &
 !$omp shared(Bevol,dBevol,dustevol,ddustfrac) &
#ifdef IND_TIMESTEPS
 !$omp shared(ibin,ibinold,twas,timei) &
#endif
 !$omp firstprivate(itype) &
 !$omp private(i,hdti)
 predictor: do i=1,npart
    if (.not.isdead_or_accreted(xyzh(4,i))) then
#ifdef IND_TIMESTEPS
       if (iactive(iphase(i))) ibinold(i) = ibin(i)
       !
       !--synchronise all particles to their half timesteps
       !
       hdti = twas(i) - timei
#else
       hdti = hdtsph
#endif
       if (store_itype) itype = iamtype(iphase(i))
       if (itype==iboundary) cycle predictor
       !
       ! predict v and u to the half step with "slow" forces
       !
       vxyzu(:,i) = vxyzu(:,i) + hdti*fxyzu(:,i)
       if (itype==igas) then
          if (mhd)          Bevol(:,i)  = Bevol(:,i) + real(hdti,kind=4)*dBevol(:,i)
          if (use_dustfrac) dustevol(i) = abs(dustevol(i) + hdti*ddustfrac(i))
       endif
    endif
 enddo predictor
 !omp end parallel do

!----------------------------------------------------------------------
! substepping with external and sink particle forces, using dtextforce
! accretion onto sinks/potentials also happens during substepping
!----------------------------------------------------------------------
 if (nptmass > 0 .or. iexternalforce > 0 .or. (h2chemistry .and. icooling > 0) .or. damp > 0.) then
    call step_extern(npart,ntypes,dtsph,dtextforce,xyzh,vxyzu,fext,t,damp,nptmass,xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass)
 else
    call step_extern_sph(dtsph,npart,xyzh,vxyzu)
 endif

 timei = timei + dtsph
!----------------------------------------------------
! interpolation of SPH quantities needed in the SPH
! force evaluations, using dtsph
!----------------------------------------------------
!$omp parallel do default(none) schedule(guided,1) &
!$omp shared(xyzh,vxyzu,vpred,fxyzu,divcurlv,npart,store_itype) &
!$omp shared(Bevol,dBevol,Bpred,dtsph,massoftype,iphase) &
!$omp shared(dustevol,dustfrac,ddustfrac,dustpred) &
!$omp shared(alphaind,ieos,alphamax) &
#ifdef IND_TIMESTEPS
!$omp shared(twas,timei) &
#endif
!$omp private(hi,rhoi,tdecay1,source,ddenom,hdti) &
!$omp private(i,spsoundi,alphaloci,divvdti) &
!$omp firstprivate(pmassi,itype,avdecayconst,alpha)
 predict_sph: do i=1,npart
    if (.not.isdead_or_accreted(xyzh(4,i))) then
       if (store_itype) then
          itype = iamtype(iphase(i))
          pmassi = massoftype(itype)
          if (itype==iboundary) then
             vpred(:,i) = vxyzu(:,i)
             if (mhd)          Bpred(:,i)  = Bevol (:,i)
             if (use_dustfrac) dustpred(i) = dustevol(i)
             cycle predict_sph
          endif
       endif
       !
       ! make prediction for h
       !
       if (ndivcurlv >= 1) then
          xyzh(4,i) = xyzh(4,i) - dtsph*dhdrho(xyzh(4,i),pmassi)*rhoh(xyzh(4,i),pmassi)*divcurlv(1,i)
       endif
       !
       ! make a prediction for v and u to the full step for use in the
       ! force evaluation. These have already been updated to the
       ! half step, so only need a half step (0.5*dtsph) here
       !
#ifdef IND_TIMESTEPS
       hdti = timei - twas(i)   ! interpolate to end time
#else
       hdti = 0.5*dtsph
#endif
       vpred(:,i) = vxyzu(:,i) + hdti*fxyzu(:,i)
       if (itype==igas) then
          if (mhd)          Bpred(:,i)  = Bevol (:,i) + real(hdti,kind=4)*dBevol(:,i)
          if (use_dustfrac) then
             rhoi        = rhoh(xyzh(4,i),pmassi)
             dustpred(i) = dustevol(i) + hdti*ddustfrac(i)
             dustfrac(i) = min(dustpred(i)**2/rhoi,1.) ! dustevol = sqrt(rho*eps)
          endif
       endif
       !
       ! viscosity switch ONLY (conductivity and resistivity do not use MM97-style switches)
       !
       if (maxalpha==maxp) then
          hi   = xyzh(4,i)
          rhoi = rhoh(hi,pmassi)
          spsoundi = get_spsound(ieos,xyzh(:,i),rhoi,vpred(:,i))
          tdecay1  = avdecayconst*spsoundi/hi
          ddenom   = 1./(1. + dtsph*tdecay1) ! implicit integration for decay term
          if (nalpha >= 2) then
             ! Cullen and Dehnen (2010) switch
             alphaloci = alphaind(2,i)
             if (alphaind(1,i) < alphaloci) then
                alphaind(1,i) = real(alphaloci,kind=kind(alphaind))
             else
                alphaind(1,i) = real((alphaind(1,i) + dtsph*alphaloci*tdecay1)*ddenom,kind=kind(alphaind))
             endif
          else
             if (ndivcurlv < 1) call fatal('step','alphaind used but divv not stored')
             ! MM97
             source = max(0.0_4,-divcurlv(1,i))
             alphaind(1,i) = real(min((alphaind(1,i) + dtsph*(source + alpha*tdecay1))*ddenom,alphamax),kind=kind(alphaind))
          endif
       endif
    endif
 enddo predict_sph
 !$omp end parallel do
!
! recalculate all SPH forces, and new timestep
!
 if ((iexternalforce /= 0 .or. nptmass > 0) .and. id==master .and. iverbose >= 2) &
   write(iprint,"(a,f14.6,/)") '> full step            : t=',timei
 if (npart > 0) call derivs(1,npart,nactive,xyzh,vpred,fxyzu,fext,divcurlv,&
                     divcurlB,Bpred,dBevol,dustfrac,ddustfrac,timei,dtsph,dtnew)
!
! if using super-timestepping, determine what dt will be used on the next loop
!
#ifdef IND_TIMESTEPS
 if ( use_sts ) call sts_get_dtau_next(dtsph_next,dtsph,dtmax,dtdiff,nbinmax)
 dtmaxold = dtmax
 if (mod_dtmax_in_step .and. sts_it_n) call decrease_dtmax(npart,dtmax_rat,dtmax,ibin,ibinsts,mod_dtmax_in_step)
#endif
!
!-------------------------------------------------------------------------
!  leapfrog corrector step: most of the time we should not need to take
!  any extra iterations, but to be reversible for velocity-dependent
!  forces we must iterate until velocities agree.
!-------------------------------------------------------------------------
 its        = 0
 converged  = .false.
 errmaxmean = 0.0
 iterations: do while (its < maxits .and. .not.converged)
    its     = its + 1
    errmax  = 0.
    v2mean  = 0.
    np      = 0
    itype   = igas
    pmassi  = massoftype(igas)
    ntypes  = get_ntypes(npartoftype)
    store_itype = (maxphase==maxp .and. ntypes > 1)
!$omp parallel default(none) &
!$omp shared(xyzh,vxyzu,vpred,fxyzu,npart,hdtsph,store_itype) &
!$omp shared(Bevol,dBevol,iphase,its) &
!$omp shared(dustevol,ddustfrac) &
!$omp shared(xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass,nptmass,massoftype) &
#ifdef IND_TIMESTEPS
!$omp shared(dtmax,dtmaxold,ibin,ibinold,twas,timei,use_sts,dtsph_next) &
!$omp private(hdti) &
#endif
!$omp private(i,vxi,vyi,vzi,vxoldi,vyoldi,vzoldi) &
!$omp private(erri,v2i,eni) &
!$omp reduction(max:errmax) &
!$omp reduction(+:np,v2mean) &
!$omp firstprivate(pmassi,itype)
!$omp do
    corrector: do i=1,npart
       if (.not.isdead_or_accreted(xyzh(4,i))) then
          if (store_itype) itype = iamtype(iphase(i))
          if (itype==iboundary) cycle corrector
#ifdef IND_TIMESTEPS
          !
          !--update active particles
          !
          if (iactive(iphase(i))) then
             if (use_sts) then
                hdti = sts_get_hdti(i,dtmax,dtsph_next,ibin(i))
             else
                hdti = 0.5*get_dt(dtmaxold,ibinold(i)) + 0.5*get_dt(dtmax,ibin(i))
             endif
             vxyzu(:,i) = vxyzu(:,i) + hdti*fxyzu(:,i)
             if (itype==igas) then
                if (mhd)          Bevol(:,i)  = Bevol(:,i) + real(hdti,kind=4)*dBevol(:,i)
                if (use_dustfrac) dustevol(i) = dustevol(i) + hdti*ddustfrac(i)
             endif
             twas(i)    = twas(i) + hdti
          endif
          !
          !--synchronise all particles
          !
          hdti = timei - twas(i)
          vxyzu(:,i) = vxyzu(:,i) + hdti*fxyzu(:,i)

          if (itype==igas) then
             if (mhd)          Bevol(:,i)  = Bevol(:,i) + real(hdti,kind=4)*dBevol(:,i)
             if (use_dustfrac) dustevol(i) = dustevol(i) + hdti*ddustfrac(i)
          endif
#else
          !
          ! For velocity-dependent forces compare the new v
          ! with the predicted v used in the force evaluation.
          ! Determine whether or not we need to iterate.
          !
          vxi = vxyzu(1,i) + hdtsph*fxyzu(1,i)
          vyi = vxyzu(2,i) + hdtsph*fxyzu(2,i)
          vzi = vxyzu(3,i) + hdtsph*fxyzu(3,i)
          if (maxvxyzu >= 4) eni = vxyzu(4,i) + hdtsph*fxyzu(4,i)

          erri = (vxi - vpred(1,i))**2 + (vyi - vpred(2,i))**2 + (vzi - vpred(3,i))**2
          !if (erri > errmax) print*,id,' errmax = ',erri,' part ',i,vxi,vxoldi,vyi,vyoldi,vzi,vzoldi
          errmax = max(errmax,erri)

          v2i = vxi*vxi + vyi*vyi + vzi*vzi
          v2mean = v2mean + v2i
          np = np + 1

          vxyzu(1,i) = vxi
          vxyzu(2,i) = vyi
          vxyzu(3,i) = vzi
          !--this is the energy equation if non-isothermal
          if (maxvxyzu >= 4) vxyzu(4,i) = eni

          if (itype==igas) then
             !
             ! corrector step for magnetic field and dust
             !
             if (mhd)          Bevol(:,i) = Bevol(:,i) + real(hdtsph,kind=4)*dBevol(:,i)
             if (use_dustfrac) dustevol(i) = dustevol(i) + hdtsph*ddustfrac(i)
          endif
#endif
       endif
    enddo corrector
!$omp enddo
!$omp end parallel

 call check_velocity_error(errmax,v2mean,np,its,tolv,dtsph,timei,dterr,errmaxmean,converged)

 if (.not.converged .and. npart > 0) then
    !$omp parallel do private(i) schedule(static)
    do i=1,npart
       if (store_itype) itype = iamtype(iphase(i))
#ifdef IND_TIMESTEPS
       if (iactive(iphase(i))) then
          vpred(:,i) = vxyzu(:,i)
          if (mhd) Bpred(:,i) = Bevol(:,i)
          if (use_dustfrac) dustpred(i) = dustevol(i)
       endif
#else
       vpred(:,i) = vxyzu(:,i)
       if (mhd) Bpred(:,i) = Bevol(:,i)
       if (use_dustfrac) dustpred(i) = dustevol(i)
!
! shift v back to the half step
!
       vxyzu(:,i) = vxyzu(:,i) - hdtsph*fxyzu(:,i)
       if (itype==igas) then
          if (mhd)          Bevol(:,i)  = Bevol(:,i) - real(hdtsph,kind=4)*dBevol(:,i)
          if (use_dustfrac) dustevol(i) = dustevol(i) - hdtsph*ddustfrac(i)
       endif
#endif
    enddo
    !$omp end parallel do
!
!   get new force using updated velocity: no need to recalculate density etc.
!
    call derivs(2,npart,nactive,xyzh,vpred,fxyzu,fext,divcurlv,divcurlB,Bpred,dBevol,dustfrac,ddustfrac,timei,dtsph,dtnew)

 endif

 enddo iterations

 if (its > 1) call summary_variable('tolv',iosumtvi,0,real(its))

 if (maxits > 1 .and. its >= maxits) then
    call summary_printout(iprint,nptmass)
    call fatal('step','VELOCITY ITERATIONS NOT CONVERGED!!')
 endif

 return
end subroutine step

!----------------------------------------------------------------
!+
!  This is the equivalent of the routine below when no external
!  forces, sink particles or cooling are used
!+
!----------------------------------------------------------------
subroutine step_extern_sph(dt,npart,xyzh,vxyzu)
 use part, only:isdead_or_accreted
 real,    intent(in)    :: dt
 integer, intent(in)    :: npart
 real,    intent(inout) :: xyzh(:,:)
 real,    intent(in)    :: vxyzu(:,:)
 integer :: i

 !$omp parallel do default(none) &
 !$omp shared(npart,xyzh,vxyzu,dt) &
 !$omp private(i)
 do i=1,npart
    if (.not.isdead_or_accreted(xyzh(4,i))) then
       !
       ! main position update
       !
       xyzh(1,i) = xyzh(1,i) + dt*vxyzu(1,i)
       xyzh(2,i) = xyzh(2,i) + dt*vxyzu(2,i)
       xyzh(3,i) = xyzh(3,i) + dt*vxyzu(3,i)
    endif
 enddo
 !$omp end parallel do

end subroutine step_extern_sph

!----------------------------------------------------------------
!+
!  Substepping of external and sink particle forces.
!  Also updates position of all particles even if no external
!  forces applied. This is the internal loop of the RESPA
!  algorithm over the "fast" forces.
!+
!----------------------------------------------------------------
subroutine step_extern(npart,ntypes,dtsph,dtextforce,xyzh,vxyzu,fext,time,damp,nptmass,xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass)
 use dim,            only:maxptmass,maxp,maxvxyzu
 use io,             only:iverbose,id,master,iprint,warning
 use externalforces, only:externalforce,accrete_particles,update_externalforce, &
                          update_vdependent_extforce_leapfrog,is_velocity_dependent
 use ptmass,         only:ptmass_predictor,ptmass_corrector,ptmass_accrete, &
                          get_accel_sink_gas,get_accel_sink_sink,f_acc,pt_write_sinkev
 use options,        only:iexternalforce
 use part,           only:maxphase,abundance,nabundances,h2chemistry,epot_sinksink,&
                          isdead_or_accreted,iboundary,igas,iphase,iamtype,massoftype,rhoh
 use options,        only:icooling
 use chem,           only:energ_h2cooling
 use io_summary,     only:summary_variable,iosumextsr,iosumextst,iosumexter,iosumextet,iosumextr,iosumextt, &
                          summary_accrete,summary_accrete_fail
 use timestep,       only:bignumber,C_force
 use timestep_sts,   only:sts_it_n
 integer, intent(in)    :: npart,ntypes,nptmass
 real,    intent(in)    :: dtsph,time,damp
 real,    intent(inout) :: dtextforce
 real,    intent(inout) :: xyzh(:,:),vxyzu(:,:),fext(:,:)
 real,    intent(inout) :: xyzmh_ptmass(:,:),vxyz_ptmass(:,:),fxyz_ptmass(:,:)
 integer :: i,itype,nsubsteps,idudtcool,ichem,naccreted,nfail,nfaili
 logical :: accreted,extf_is_velocity_dependent
 real    :: timei,hdt,fextx,fexty,fextz,fextxi,fextyi,fextzi,phii,pmassi
 real    :: dtphi2,dtphi2i,vxhalfi,vyhalfi,vzhalfi,fxi,fyi,fzi,deni
 real    :: dudtcool,fextv(3),fac,poti
 real    :: xyzm_ptmass_old(4,nptmass),vxyz_ptmass_old(3,nptmass)
 real    :: dt,dtextforcenew,dtsinkgas,fonrmax,fonrmaxi
 real    :: dtf,accretedmass,t_end_step,dtextforce_min
 real, save :: fxyz_ptmass_thread(4,maxptmass)
 real, save :: dmdt = 0.
 logical :: last_step,done
 !$omp threadprivate(fxyz_ptmass_thread)
!
! determine whether or not to use substepping
!
 if ((iexternalforce > 0 .or. nptmass > 0) .and. dtextforce < dtsph) then
    dt = dtextforce
    last_step = .false.
 else
    dt = dtsph
    last_step = .true.
 endif

 timei = time
 extf_is_velocity_dependent = is_velocity_dependent(iexternalforce)
 accretedmass   = 0.
 itype          = igas
 pmassi         = massoftype(igas)
 fac            = 0.
 t_end_step     = timei + dtsph
 nsubsteps      = 0
 dtextforce_min = huge(dt)
 done           = .false.

 substeps: do while (timei <= t_end_step .and. .not.done)
    hdt           = 0.5*dt
    timei         = timei + dt
    nsubsteps     = nsubsteps + 1
    dtextforcenew = bignumber
    dtsinkgas     = bignumber
    dtphi2        = bignumber

    if (.not.last_step .and. iverbose > 1 .and. id==master) then
       write(iprint,"(a,f14.6)") '> external/ptmass forces only : t=',timei
    endif
    !
    ! update time-dependent external forces
    !
    call update_externalforce(iexternalforce,timei,dmdt)

    !---------------------------
    ! predictor during substeps
    !---------------------------
    !
    ! point mass predictor step
    !
    if (nptmass > 0) call ptmass_predictor(nptmass,dt,xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass)
    !
    ! get sink-sink forces (and a new sink-sink timestep.  Note: fxyz_ptmass is zeroed in this subroutine)
    !
    if (nptmass > 0) then
       call get_accel_sink_sink(nptmass,xyzmh_ptmass,fxyz_ptmass,epot_sinksink,dtf,iexternalforce,timei)
       dtextforcenew = min(dtextforcenew,C_force*dtf)
       if (iverbose >= 2) write(iprint,*) 'dt(sink-sink) = ',C_force*dtf
    endif

    !
    ! predictor step for sink-gas and external forces, also recompute sink-gas and external forces
    !
    fonrmax = 0.
    !$omp parallel default(none) &
    !$omp shared(npart,xyzh,vxyzu,fext,abundance,iphase,ntypes,massoftype) &
    !$omp shared(dt,hdt,timei,iexternalforce,extf_is_velocity_dependent,icooling) &
    !$omp shared(xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass,damp) &
    !$omp shared(nptmass,f_acc,nsubsteps,C_force) &
    !$omp private(i,ichem,idudtcool,dudtcool,fxi,fyi,fzi,phii) &
    !$omp private(fextx,fexty,fextz,fextxi,fextyi,fextzi,poti,deni,fextv,accreted) &
    !$omp private(fonrmaxi,dtphi2i,dtf) &
    !$omp private(vxhalfi,vyhalfi,vzhalfi) &
    !$omp firstprivate(pmassi,itype) &
    !$omp reduction(+:accretedmass) &
    !$omp reduction(min:dtextforcenew,dtsinkgas,dtphi2) &
    !$omp reduction(max:fonrmax)
    fxyz_ptmass_thread(:,1:nptmass) = 0.
    !$omp do
    predictor: do i=1,npart
       if (.not.isdead_or_accreted(xyzh(4,i))) then
          if (ntypes > 1 .and. maxphase==maxp) then
             itype = iamtype(iphase(i))
             pmassi = massoftype(itype)
          endif
          !
          ! predict v to the half step
          !
          vxyzu(1:3,i) = vxyzu(1:3,i) + hdt*fext(1:3,i)
          !
          ! main position update
          !
          xyzh(1,i) = xyzh(1,i) + dt*vxyzu(1,i)
          xyzh(2,i) = xyzh(2,i) + dt*vxyzu(2,i)
          xyzh(3,i) = xyzh(3,i) + dt*vxyzu(3,i)
          !
          ! Skip remainder of update if boundary particle; note that fext==0 for these particles
          if (itype==iboundary) cycle predictor
          !
          ! compute and add sink-gas force
          !
          fextx = 0.
          fexty = 0.
          fextz = 0.
          if (nptmass > 0) then
             call get_accel_sink_gas(nptmass,xyzh(1,i),xyzh(2,i),xyzh(3,i),xyzh(4,i),xyzmh_ptmass,&
                      fextx,fexty,fextz,phii,pmassi,fxyz_ptmass_thread,fonrmaxi,dtphi2i)
             fonrmax = max(fonrmax,fonrmaxi)
             dtphi2  = min(dtphi2,dtphi2i)
          endif
          !
          ! compute and add external forces
          !
          if (iexternalforce > 0) then
             call externalforce(iexternalforce,xyzh(1,i),xyzh(2,i),xyzh(3,i),xyzh(4,i), &
                                timei,fextxi,fextyi,fextzi,poti,dtf,i)
             dtextforcenew = min(dtextforcenew,C_force*dtf)

             fextx = fextx + fextxi
             fexty = fexty + fextyi
             fextz = fextz + fextzi
             !
             !  Velocity-dependent external forces require special handling
             !  in leapfrog (corrector is implicit)
             !
             if (extf_is_velocity_dependent) then
                vxhalfi = vxyzu(1,i)
                vyhalfi = vxyzu(2,i)
                vzhalfi = vxyzu(3,i)
                fxi = fextx
                fyi = fexty
                fzi = fextz
                call update_vdependent_extforce_leapfrog(iexternalforce,&
                     vxhalfi,vyhalfi,vzhalfi, &
                     fxi,fyi,fzi,fextv,dt,xyzh(1,i),xyzh(2,i),xyzh(3,i))
                fextx = fextx + fextv(1)
                fexty = fexty + fextv(2)
                fextz = fextz + fextv(3)
             endif
          endif
          if (damp > 0.) then
             fextx = fextx - damp*vxyzu(1,i)
             fexty = fexty - damp*vxyzu(2,i)
             fextz = fextz - damp*vxyzu(3,i)
          endif
          fext(1,i) = fextx
          fext(2,i) = fexty
          fext(3,i) = fextz
          !
          ! ARP added:
          ! Chemistry must be updated on each substep, else will severely underestimate.
          !
          if ((maxvxyzu >= 4).and.(icooling > 0).and.h2chemistry) then
             !--Flag determines no cooling, just update abundances.
             ichem     = 1
             idudtcool = 0
             !--Dummy variable to fill for cooling (will remain empty)
             dudtcool  = 0.
             !--Provide a blank dudt_cool element, not needed here
             call energ_h2cooling(vxyzu(4,i),dudtcool,rhoh(xyzh(4,i),pmassi),abundance(:,i), &
                                  nabundances,dt,xyzh(1,i),xyzh(2,i),xyzh(3,i),idudtcool,ichem)
          endif
       endif
    enddo predictor
    !$omp enddo

    !
    ! reduction of sink-gas forces from each thread
    !
    if (nptmass > 0 .and. npart > 0) then
       !$omp critical(ptmassadd)
       fxyz_ptmass(:,1:nptmass) = fxyz_ptmass(:,1:nptmass) + fxyz_ptmass_thread(:,1:nptmass)
       !$omp end critical(ptmassadd)
    endif
    !$omp end parallel

    !---------------------------
    ! corrector during substeps
    !---------------------------
    !
    ! corrector step on sinks (changes velocities only, does not change position)
    !
    if (nptmass > 0) then
       call ptmass_corrector(nptmass,dt,vxyz_ptmass,fxyz_ptmass,xyzmh_ptmass,iexternalforce)
    endif

    !
    ! Save sink particle properties for use in checks to see if particles should be accreted
    !
    if (nptmass /= 0) then
       xyzm_ptmass_old = xyzmh_ptmass(1:4,1:nptmass)
       vxyz_ptmass_old = vxyz_ptmass (1:3,1:nptmass)
    endif

    !
    ! corrector step on gas particles (also accrete particles at end of step)
    !
    accretedmass = 0.
    nfail        = 0
    naccreted    = 0
    !$omp parallel do default(none) &
    !$omp shared(npart,xyzh,vxyzu,fext,iphase,ntypes,massoftype,hdt,timei,nptmass,sts_it_n) &
    !$omp shared(xyzmh_ptmass,vxyz_ptmass,fxyz_ptmass,f_acc) &
    !$omp shared(iexternalforce,vxyz_ptmass_old,xyzm_ptmass_old) &
    !$omp private(i,accreted,nfaili,fxi,fyi,fzi) &
    !$omp firstprivate(itype,pmassi) &
    !$omp reduction(+:accretedmass,nfail,naccreted)
    accreteloop: do i=1,npart
       if (.not.isdead_or_accreted(xyzh(4,i))) then
          if (ntypes > 1 .and. maxphase==maxp) then
             itype = iamtype(iphase(i))
             pmassi = massoftype(itype)
             if (itype==iboundary) cycle accreteloop
          endif
          !
          ! correct v to the full step using only the external force
          !
          vxyzu(1:3,i) = vxyzu(1:3,i) + hdt*fext(1:3,i)

          if (iexternalforce > 0) then
             call accrete_particles(iexternalforce,xyzh(1,i),xyzh(2,i), &
                                    xyzh(3,i),xyzh(4,i),pmassi,timei,accreted)
             if (accreted) accretedmass = accretedmass + pmassi
          endif
          !
          ! accretion onto sink particles
          ! need position, velocities and accelerations of both gas and sinks to be synchronised,
          ! otherwise will not conserve momentum
          ! Note: requiring sts_it_n since this is supertimestep with the most active particles
          !
          if (nptmass > 0 .and. sts_it_n) then
             fxi = fext(1,i)
             fyi = fext(2,i)
             fzi = fext(3,i)
             call ptmass_accrete(1,nptmass,xyzh(1,i),xyzh(2,i),xyzh(3,i),xyzh(4,i),&
                                 vxyzu(1,i),vxyzu(2,i),vxyzu(3,i),fxi,fyi,fzi,&
                                 itype,pmassi,xyzmh_ptmass,xyzm_ptmass_old,vxyz_ptmass, &
                                 vxyz_ptmass_old,fxyz_ptmass,accreted,timei,f_acc,nfaili)
             if (accreted) then
                naccreted = naccreted + 1
                cycle accreteloop
             endif
             if (nfaili > 1) nfail = nfail + 1
          endif
       endif
    enddo accreteloop
    !$omp end parallel do

    if (iverbose >= 2 .and. id==master .and. naccreted /= 0) write(iprint,"(a,es10.3,a,i4,a,i4,a)") &
       'Step: at time ',timei,', ',naccreted,' particles were accreted amongst ',nptmass,' sink(s).'

    if (nptmass > 0) then
       call summary_accrete_fail(nfail)
       call summary_accrete(nptmass)
       ! only write to .ev during substeps if no gas particles present
       if (npart==0) call pt_write_sinkev(nptmass,timei,xyzmh_ptmass,vxyz_ptmass)
    endif
    !
    ! check if timestep criterion was violated during substeps
    !
    if (nptmass > 0) then
       if (fonrmax > 0.) then
          dtsinkgas = min(dtsinkgas,C_force*1./sqrt(fonrmax),C_force*sqrt(dtphi2))
       endif
       if (iverbose >= 2) write(iprint,*) nsubsteps,'dt(ext/sink-sink) = ',dtextforcenew,', dt(sink-gas) = ',dtsinkgas
       dtextforcenew = min(dtextforcenew,dtsinkgas)
    endif

    dtextforce_min = min(dtextforce_min,dtextforcenew)
    dtextforce = dtextforcenew

    if (last_step) then
       done = .true.
    else
       dt = dtextforce
       if (timei + dt > t_end_step) then
          dt = t_end_step - timei
          last_step = .true.
       endif
    endif
 enddo substeps

 if (nsubsteps > 1) then
    if (iverbose>=1 .and. id==master) then
       write(iprint,"(a,i6,a,f8.2,a,es10.3,a,es10.3)") &
           ' using ',nsubsteps,' substeps (dthydro/dtextf = ',dtsph/dtextforce_min,'), dt = ',dtextforce_min,' dtsph = ',dtsph
    endif
    if (nptmass >  0 .and. iexternalforce <= 0) then
       call summary_variable('ext',iosumextsr,nsubsteps,dtsph/dtextforce_min)
       call summary_variable('ext',iosumextst,nsubsteps,dtextforce_min,1.0/dtextforce_min)
    elseif (nptmass <= 0 .and. iexternalforce >  0) then
       call summary_variable('ext',iosumexter,nsubsteps,dtsph/dtextforce_min)
       call summary_variable('ext',iosumextet,nsubsteps,dtextforce_min,1.0/dtextforce_min)
    else
       call summary_variable('ext',iosumextr ,nsubsteps,dtsph/dtextforce_min)
       call summary_variable('ext',iosumextt ,nsubsteps,dtextforce_min,1.0/dtextforce_min)
    endif
 endif

end subroutine step_extern

!-----------------------------------------------------
!+
!  Check error in v^1 compared to the predicted v^*
!  in the leapfrog corrector step. If this is not
!  within some tolerance we iterate the corrector step
!+
!-----------------------------------------------------
subroutine check_velocity_error(errmax,v2mean,np,its,tolv,dt,timei,dterr,errmaxmean,converged)
 use io,         only:id,master,iprint,iverbose
#ifndef IND_TIMESTEPS
 use timestep,   only:dtcourant,dtforce,bignumber
#endif
 use mpiutils,   only:reduceall_mpi
 use io_summary, only:summary_variable,iosumtve,iosumtvv
 real,    intent(inout) :: errmax,v2mean,errmaxmean
 integer, intent(in)    :: np,its
 real,    intent(in)    :: tolv,dt,timei
 real,    intent(out)   :: dterr
 logical, intent(out)   :: converged
 real            :: errtol,vmean
#ifndef IND_TIMESTEPS
 real            :: dtf
#endif
 integer(kind=8) :: nptot
!
!  Check v^1 against the predicted velocity
!  this will only be different because of velocity-dependent forces
!  (i.e., viscosity). If these are not a small fraction of the total force
!  we need to take iterations in order to get this right in leapfrog.
!  Also, if this occurs, we take the timestep down to try to avoid the need
!  for iterations.
!
 nptot = np
 errmax = reduceall_mpi('max',errmax)

 if (nptot > 0) then
    v2mean = v2mean/real(nptot)
 else
    v2mean = 0.
 endif
 if (v2mean > tiny(v2mean)) then
    errmax = errmax/sqrt(v2mean)
 else
    errmax = 0.
 endif
 errmaxmean = errmaxmean + errmax
 errtol = tolv
 if (tolv < 1.e2) then
#ifndef IND_TIMESTEPS
    dtf = min(dtcourant,dtforce)
    !--if errors are controlling the timestep
    if (dtf > dt .and. dtf < bignumber) then
       errtol = errtol*(dt/dtf)**2
    endif
    if (its==1) then
       if (errtol > tiny(errtol) .and. errmax > epsilon(errmax)) then ! avoid divide-by-zero
          dterr = dt*sqrt(errtol/errmax)
       endif
    endif
#endif
 endif
!
! if the error in the predicted velocity exceeds the tolerance, take iterations
!
! if (maxits > 1 .and. tolv < 1.e2) then
 if (tolv < 1.e2) then
    converged = (errmax < tolv)
    if (id==master .and. .not.converged) then
       vmean = sqrt(v2mean)
       call summary_variable('tolv',iosumtve,0,errmax)
       call summary_variable('tolv',iosumtvv,0,vmean)
    endif
    if (id==master .and.((iverbose >= 1.and.(.not.converged.or.its > 1)) .or. iverbose >= 2)) &
       write(iprint,"(a,i2,a,es10.3,a,es10.3,a)") &
            ' velocity-dependent force (tolv) iteration ',its,' errmax = ',errmax,' (vmean = ',sqrt(v2mean),')'
 else
    converged = .true.
 endif
 if (id==master .and. tolv > 1.e2 .and. errmax > 1.0d-2) &
   write(iprint,"(a,es10.3,a,es10.3,a,es10.3)") &
        ' velocity-dependent force (tolv) at time = ',timei,' with errmax = ',errmax,' and vmean = ',sqrt(v2mean)

end subroutine check_velocity_error

end module step_lf_global
