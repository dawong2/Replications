!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2017 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://users.monash.edu.au/~dprice/phantom                               !
!--------------------------------------------------------------------------!
!+
!  MODULE: dim
!
!  DESCRIPTION:
!   Module to determine storage based on compile-time configuration
!
!  REFERENCES: None
!
!  OWNER: Daniel Price
!
!  $Id$
!
!  RUNTIME PARAMETERS: None
!
!  DEPENDENCIES: None
!+
!--------------------------------------------------------------------------
module dim
 implicit none
 character(len=80), parameter :: &  ! module version
    modid="$Id$"

 public

 character(len=80), parameter :: &
    tagline='PhantomSPH: (c) 2007-2017 The Authors'

 ! maximum number of particles
#ifdef MAXP
 integer, parameter :: maxp = MAXP
#else
 integer, parameter :: maxp=1000000
#endif

 ! maximum number of point masses
#ifdef MAXPTMASS
 integer, parameter :: maxptmass = MAXPTMASS
#else
 integer, parameter :: maxptmass = 100
#endif

 ! storage of thermal energy or not
#ifdef ISOTHERMAL
 integer, parameter :: maxvxyzu = 3
#else
 integer, parameter :: maxvxyzu = 4
#endif

 ! maximum allowable number of neighbours (safest=maxp)
#ifdef MAXNEIGH
 integer, parameter :: maxneigh = MAXNEIGH
#else
 integer, parameter :: maxneigh = maxp
#endif

 ! maxmimum storage in linklist
#ifdef NCELLSMAX
 integer, parameter :: ncellsmax = NCELLSMAX
#else
 integer, parameter :: ncellsmax = maxp
#endif

 ! storage for artificial viscosity switch
#ifdef DISC_VISCOSITY
 integer, parameter :: maxalpha = 0
 integer, parameter :: nalpha = 0
#else
#ifdef CONST_AV
 integer, parameter :: maxalpha = 0
 integer, parameter :: nalpha = 0
#else
 integer, parameter :: maxalpha = maxp
#ifdef USE_MORRIS_MONAGHAN
 integer, parameter :: nalpha = 1
#else
 integer, parameter :: nalpha = 2
#endif
#endif
#endif

 ! optional storage of curl v
#ifdef CURLV
 integer, parameter :: ndivcurlv = 4
#else
 integer, parameter :: ndivcurlv = 1
#endif

 ! periodic boundaries
#ifdef PERIODIC
 logical, parameter :: periodic = .true.
#else
 logical, parameter :: periodic = .false.
#endif

 !
 ! Maximum number of particle types
 !
 integer, parameter :: maxtypes = 6

 !
 ! Number of dimensions, where it is needed
 ! (Phantom is hard wired to ndim=3 in a lot of
 !  places; changing this does NOT change the
 !  code dimensionality, it just allows routines
 !  to be written in a way that are agnostic to
 !  the number of dimensions)
 !
 integer, parameter :: ndim = 3

!-----------------
! Magnetic fields
!-----------------
#ifdef MHD
 logical, parameter :: mhd = .true.
 integer, parameter :: maxmhd = maxp
 integer, parameter :: maxBevol = 4  ! Bx,By,Bz,Psi (latter for div B cleaning)
 integer, parameter :: maxvecp = 0   ! obsolete, used for vector/Euler pots (no longer supported)
 integer, parameter :: ndivcurlB = 4
#else
 ! if no MHD, do not store any of these
 logical, parameter :: mhd = .false.
 integer, parameter :: maxmhd = 0
 integer, parameter :: maxvecp = 0 ! obsolete
 integer, parameter :: maxBevol = 4 ! irrelevant, but prevents compiler warnings
 integer, parameter :: ndivcurlB = 0
#endif

! non-ideal MHD
#ifdef MHD
#ifdef NONIDEALMHD
 logical, parameter :: mhd_nonideal = .true.
 integer, parameter :: maxmhdni     = maxp
#else
 logical, parameter :: mhd_nonideal = .false.
 integer, parameter :: maxmhdni     = 0
#endif
#else
 logical, parameter :: mhd_nonideal = .false.
 integer, parameter :: maxmhdni     = 0
#endif

!--------------------
! Physical viscosity
!--------------------
!
! storage of strain tensor, necessary if
! physical viscosity is done with two
! first derivatives
!
#ifdef USE_STRAIN_TENSOR
 integer, parameter :: maxstrain = maxp
#else
 integer, parameter :: maxstrain = 0
#endif

! viscosity switches, whether done in step or during derivs call
 logical, parameter :: switches_done_in_derivs = .false.

!------
! Dust
!------
#ifdef DUST
 logical, parameter :: use_dust = .true.
 integer, parameter :: ndusttypes = 1
#else
 logical, parameter :: use_dust = .false.
 integer, parameter :: ndusttypes = 0
#endif

#ifdef DUSTFRAC
 logical, parameter :: use_dustfrac = .true.
 integer, parameter :: maxp_dustfrac = maxp
#else
 logical, parameter :: use_dustfrac = .false.
 integer, parameter :: maxp_dustfrac = maxp
#endif

!--------------------
! H2 Chemistry
!--------------------
#ifdef H2CHEM
 logical, parameter :: h2chemistry = .true.
 integer, parameter :: maxp_h2 = maxp
#else
 logical, parameter :: h2chemistry = .false.
 integer, parameter :: maxp_h2 = 0
#endif

!--------------------
! Self-gravity
!--------------------
#ifdef GRAVITY
 logical, parameter :: gravity = .true.
 integer, parameter :: maxgrav = maxp
 integer, parameter :: ngradh = 2
#else
 logical, parameter :: gravity = .false.
 integer, parameter :: maxgrav = 0
 integer, parameter :: ngradh = 1
#endif

!--------------------
! Supertimestepping
!--------------------
#ifdef STS_TIMESTEPS
#ifdef IND_TIMESTEPS
 integer, parameter  :: maxsts = maxp
#else
 integer, parameter  :: maxsts = 1
#endif
#else
 integer, parameter  :: maxsts = 1
#endif

!--------------------
! Light curve stuff
!--------------------
#ifdef LIGHTCURVE
 integer, parameter :: maxlum = maxp
 logical, parameter :: lightcurve = .true.
#else
 integer, parameter :: maxlum = 0
 logical, parameter :: lightcurve = .false.
#endif

!--------------------
! Calculate rotational energy in .ev
!--------------------
 logical, public :: calc_erot     = .false.
 logical, public :: calc_erot_com = .false.
 logical, public :: incl_erot     = .false.

end module dim


