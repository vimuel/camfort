!!!!!!!!!!!!!!!!!!!!!!!!!!!   Program 2.13   !!!!!!!!!!!!!!!!!!!!!!!!!!!!
!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!                                                                       !
! Please Note:                                                          !
!                                                                       !
! (1) This computer program is written by Tao Pang in conjunction with  !
!     his book, "An Introduction to Computational Physics," published   !
!     by Cambridge University Press in 1997.                            !
!                                                                       !
! (2) No warranties, express or implied, are made for this program.     !
!                                                                       !
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!
!MODULE CSEED
!  INTEGER :: ISEED
!END MODULE CSEED
!
SUBROUTINE GRNF (X,Y)
!
! Two Gaussian random numbers generated from two uniform random
! numbers. Copyright (c) Tao Pang 1997.
!
  IMPLICIT NONE
  REAL, INTENT (OUT) :: X,Y
  REAL :: PI,R1,R2,R,RANF
!
  PI = 4.0*ATAN(1.0)
  R1 = -ALOG(1.0-RANF())
  R2 = 2.0*PI*RANF()
  R1 = SQRT(2.0*R1)
  X  = R1*COS(R2)
  Y  = R1*SIN(R2)
END SUBROUTINE GRNF
!
FUNCTION RANF() RESULT (R)
!
! Uniform random number generator x(n+1) = a*x(n) mod c with
! a=7**5 and c = 2**(31)-1.  Copyright (c) Tao Pang 1997.
!
!  USE CSEED
 
  IMPLICIT NONE
INTEGER :: ISEED
  INTEGER :: IH,IL,IT,IA,IC,IQ,IR
  DATA IA/16807/,IC/2147483647/,IQ/127773/,IR/2836/
  REAL :: R
!
  IH = ISEED/IQ
  IL = MOD(ISEED,IQ)
  IT = IA*IL-IR*IH
  IF(IT.GT.0) THEN
    ISEED = IT
  ELSE
    ISEED = IC+IT
  END IF
  R = ISEED/FLOAT(IC)
END FUNCTION RANF
