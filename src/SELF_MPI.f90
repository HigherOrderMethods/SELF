!
! Copyright 2020 Fluid Numerics LLC
! Author : Joseph Schoonover (joe@fluidnumerics.com)
! Support : self@higherordermethods.org
!
! //////////////////////////////////////////////////////////////////////////////////////////////// !
MODULE SELF_MPI

  USE SELF_Constants
  USE SELF_Memory
  USE ISO_C_BINDING
  USE MPI

  IMPLICIT NONE

#include "SELF_Macros.h"

  TYPE MPILayer
    LOGICAL :: mpiEnabled
    INTEGER :: mpiComm
    INTEGER :: mpiPrec
    INTEGER :: rankId
    INTEGER :: nRanks
    INTEGER :: nElem
    INTEGER :: maxMsg
    INTEGER :: msgCount
    TYPE(hfInt32_r1) :: elemToRank
    TYPE(hfInt32_r1) :: offSetElem
    INTEGER, ALLOCATABLE :: requests(:)
    INTEGER, ALLOCATABLE :: stats(:,:)

  CONTAINS

    PROCEDURE :: Init => Init_MPILayer
    PROCEDURE :: Free => Free_MPILayer
    PROCEDURE :: Finalize => Finalize_MPILayer

    PROCEDURE :: SetElemToRank
    PROCEDURE :: SetMaxMsg

    PROCEDURE,PUBLIC :: FinalizeMPIExchangeAsync

  END TYPE MPILayer

CONTAINS

  SUBROUTINE Init_MPILayer(this,enableMPI)
#undef __FUNC__
#define __FUNC__ "Init_MPILayer"
    IMPLICIT NONE
    CLASS(MPILayer),INTENT(out) :: this
    LOGICAL,INTENT(in) :: enableMPI
    ! Local
    INTEGER       :: ierror
    CHARACTER(30) :: msg

    this % mpiComm = 0
    this % mpiPrec = prec
    this % rankId = 0
    this % nRanks = 1
    this % nElem = 0
    this % mpiEnabled = enableMPI

    IF (enableMPI) THEN
      this % mpiComm = MPI_COMM_WORLD
      CALL MPI_INIT(ierror)
      CALL MPI_COMM_RANK(this % mpiComm,this % rankId,ierror)
      CALL MPI_COMM_SIZE(this % mpiComm,this % nRanks,ierror)
    END IF

    IF (prec == real32) THEN
      this % mpiPrec = MPI_FLOAT
    ELSE
      this % mpiPrec = MPI_DOUBLE
    END IF

    CALL this % offSetElem % Alloc(0,this % nRanks)

    WRITE (msg,'(I5)') this % rankId
    msg = "Greetings from rank "//TRIM(msg)//"."
    INFO(TRIM(msg))

  END SUBROUTINE Init_MPILayer

  SUBROUTINE Free_MPILayer(this)
    IMPLICIT NONE
    CLASS(MPILayer),INTENT(inout) :: this

    CALL this % offSetElem % Free()
    CALL this % elemToRank % Free()

    DEALLOCATE( this % requests )
    DEALLOCATE( this % stats )

  END SUBROUTINE Free_MPILayer

  SUBROUTINE Finalize_MPILayer(this)
#undef __FUNC__
#define __FUNC__ "Finalize_MPILayer"
    IMPLICIT NONE
    CLASS(MPILayer),INTENT(inout) :: this
    ! Local
    INTEGER       :: ierror
    CHARACTER(30) :: msg

    IF (this % mpiEnabled) THEN
      WRITE (msg,'(I5)') this % rankId
      msg = "Goodbye from rank "//TRIM(msg)//"."
      INFO(TRIM(msg))
      CALL MPI_FINALIZE(ierror)
    ENDIF

  END SUBROUTINE Finalize_MPILayer

  SUBROUTINE SetMaxMsg(this,maxMsg)
    IMPLICIT NONE
    CLASS(MPILayer),INTENT(inout) :: this
    INTEGER,INTENT(in) :: maxMsg

    ALLOCATE( this % requests(1:maxMsg) )
    ALLOCATE( this % stats(MPI_STATUS_SIZE,1:maxMsg) )
    this % maxMsg = maxMsg

  END SUBROUTINE SetMaxMsg

  SUBROUTINE SetElemToRank(this,nElem)
    IMPLICIT NONE
    CLASS(MPILayer),INTENT(inout) :: this
    INTEGER,INTENT(in) :: nElem
    ! Local
    INTEGER :: iel

    this % nElem = nElem
    CALL this % elemToRank % Alloc(1,nElem)
    CALL DomainDecomp(nElem, &
                      this % nRanks, &
                      this % offSetElem % hostData)

    DO iel = 1,nElem
      CALL ElemToRank(this % nRanks, &
                      this % offSetElem % hostData, &
                      iel, &
                      this % elemToRank % hostData(iel))
    END DO

    CALL this % offSetElem % UpdateDevice()
    CALL this % elemToRank % UpdateDevice()

  END SUBROUTINE SetElemToRank

  SUBROUTINE DomainDecomp(nElems,nDomains,offSetElem)
    ! From https://www.hopr-project.org/externals/Meshformat.pdf, Algorithm 4
    IMPLICIT NONE
    INTEGER,INTENT(in) :: nElems
    INTEGER,INTENT(in) :: nDomains
    INTEGER,INTENT(out) :: offsetElem(0:nDomains)
    ! Local
    INTEGER :: nLocalElems
    INTEGER :: remainElems
    INTEGER :: iDom

    nLocalElems = nElems/nDomains
    remainElems = nElems - nLocalElems*nDomains
    DO iDom = 0,nDomains - 1
      offSetElem(iDom) = iDom*nLocalElems + MIN(iDom,remainElems)
    END DO
    offSetElem(nDomains) = nElems

  END SUBROUTINE DomainDecomp

  SUBROUTINE ElemToRank(nDomains,offsetElem,elemID,domain)
    ! From https://www.hopr-project.org/externals/Meshformat.pdf, Algorithm 7
    !   "Find domain containing element index"
    !
    IMPLICIT NONE
    INTEGER,INTENT(in) :: nDomains
    INTEGER,INTENT(in) :: offsetElem(0:nDomains)
    INTEGER,INTENT(in) :: elemID
    INTEGER,INTENT(out) :: domain
    ! Local
    INTEGER :: maxSteps
    INTEGER :: low,up,mid
    INTEGER :: i

    domain = 0
    maxSteps = INT(LOG10(REAL(nDomains))/LOG10(2.0)) + 1
    low = 0
    up = nDomains - 1

    IF (offsetElem(low) < elemID .AND. elemID <= offsetElem(low + 1)) THEN
      domain = low
    ELSEIF (offsetElem(up) < elemID .AND. elemID <= offsetElem(up + 1)) THEN
      domain = up
    ELSE
      DO i = 1,maxSteps
        mid = (up - low)/2 + low
        IF (offsetElem(mid) < elemID .AND. elemID <= offsetElem(mid + 1)) THEN
          domain = mid
          RETURN
        ELSEIF (elemID > offsetElem(mid + 1)) THEN
          low = mid + 1
        ELSE
          up = mid
        END IF
      END DO
    END IF

  END SUBROUTINE ElemToRank

  SUBROUTINE FinalizeMPIExchangeAsync(mpiHandler)
    CLASS(MPILayer),INTENT(inout) :: mpiHandler
    ! Local
    INTEGER :: ierror

    CALL MPI_WaitAll(mpiHandler % msgCount, &
                     mpiHandler % requests(1:mpiHandler % msgCount), &
                     mpiHandler % stats(1:MPI_STATUS_SIZE,1:mpiHandler % msgCount), &
                     iError)

  END SUBROUTINE FinalizeMPIExchangeAsync

END MODULE SELF_MPI
