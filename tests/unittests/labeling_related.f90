MODULE labeling_related
use num_types
use utilities_module
use enumeration_types
use vector_matrix_utilities
use numerical_utilities
use rational_mathematics, only: gcd
use combinatorics
implicit none
private
public  count_full_colorings, &
        make_member_list, make_label_rotation_table, &
        generate_unique_labelings, &       ! original algorithm for full concentration enumeration
        generate_permutation_labelings, &  ! 2011 algorithm for concentration-restricted enumeation
        write_labelings, generate_disjoint_permutation_labelings
CONTAINS

!***************************************************************************************************
!  This subroutine is conceptually the same as generate_unique_labelings. That routine generates
!  labelings as a lexicographical list of all possible labelings (all concentrations), subject to
!  label-site restrictions. This routine generates all possible *permutations* of a fixed
!  concentration of labels. See Rod's multiperms.pdf write-up (in the enumlib repository) for
!  details on how the algorithm works. Rod's approach makes it possible to design a minimal hash
!  table and perfect hash function for this list (just like we did for the combinations list in the
!  other routine).
!
!  GLWH Spring 2011
!  
! In Dec. 2011, this routine was changed so that, instead of simply
! looping over every index in the hash table (in order, as it did
! originally), the labelings are generated from a "tree structure,"
! avoiding "branches" of the tree that violate site-restrictions. It also skips
! labelings that violate multiplicity restrictions. (See enum III paper.)
! 
! GLWH Dec. 2011

SUBROUTINE generate_permutation_labelings(k,n,nD,perm,lab,iConc,parLabel,parDigit,degeneracy_list,fixed_cells)
integer, intent(in) :: k ! Number of colors/labels
integer, intent(in) :: n ! Index of the superlattice
integer, intent(in) :: nD ! Number of sites in the basis of the parent lattice (size of d-set)
integer, intent(in) :: perm(:,:) ! list of translation and rotation permutations
character, pointer :: lab(:) ! Array to store markers for every raw labeling
! I=>incomplete labeling, U=>unique, D=>rot/trans duplicate, N=>non-primitive, E=>label exchange
! Need to pass lab out to write out the labelings
integer, intent(in) :: iConc(:) ! concentration; the numerator of each rational number that is the
                                ! concentration for each label
integer, intent(in) :: parLabel(:,:) ! The *labels* (index 1) for each d-vector (index 2) in the parent
integer, intent(in) :: parDigit(:) ! The *number* of labels allowed on each site of the parent cell 
integer, pointer :: degeneracy_list(:)
logical, intent(in) :: fixed_cells ! Enumeration for user-specified cells instead of generated cells 

integer, allocatable :: temp(:)
integer index, nUniq,i
integer, allocatable:: E(:,:) ! A matrix of 1's and 0's, indicating site-restrictions
! One row for each site in the supercell, one column for each color (label)
integer(li) nL !  number of perumations (labelings)
integer status
integer q, nPerm ! loop counter for symmetry permutations
integer(li) idxOrig, idx  ! Index of unpermuted labeling, Index of a permuted labeling
integer a(n*nD) ! The current labeling depicted as a list of integers
integer ik, iD ! Loop counters for colors and sites in the supercell
integer sitePointer ! Marks the location of the current digit that is advancing
logical flag ! Use this to exit the loops once we have traversed the entire tree

lab => null()

nL = multinomial(iConc) ! The hash table is "full size" even if
! site-restrictions will reduce the size of the list
allocate(lab(nL),STAT=status)
if(status/=0) stop "Allocation of 'lab' failed in generate_permutation_labelings"
lab = ""
nPerm = size(perm,1)

! Initialize the mask (E) used to prune the tree to meet site restrictions 
allocate(E(n*nD,k))
E = 0
do ik = 1, k; do iD = 1, n*nD ! loop over all "colors" and all "sites"
   if (any(parLabel(:,(iD-1)/n+1)==ik-1)) then ! this label is allowed on this site
      E(iD,ik) = 1
   end if
end do; end do
! Write a file containing the mask for site restrictions
open(22,file="debug_site_restrictions.out",access="append")
write(22,'("site #   parent site #        Mask")') 
do iD = 1, n*nD
   write(22,'(i4,8x,i3,10x,10(i2,1x))') iD,(iD-1)/n+1,E(iD,:)
end do; write(22,*); close(22)

allocate(degeneracy_list(nL) )
degeneracy_list = 0
nUniq = 0

a = -1; flag = .true.
sitePointer = 1
do while (flag) ! Loop over digits (place holders) in the labeling
   do while (flag) ! Loop over possible values for each digit
                   ! This loop "walks the tree" until it hits a bottom branch (i.e., a complete labeling, not necessarily already a leagl labeling)
      if (sitePointer < 1) then
         flag = .false.; exit
      endif
      a(sitePointer) = a(sitePointer) + 1 ! Advance the current digit
      if (a(sitePointer) > k-1) then      ! Reset the label to zero  
         a(sitePointer) = -1             ! and back up one digit
         sitePointer = sitePointer - 1  
         cycle
      endif
      if(E(sitePointer,a(sitePointer)+1)==1) exit ! Found a valid label for this site, so exit loop
   enddo

   if(.not.flag) exit ! Done with the label generation
   if(count(a==a(sitePointer))>iConc(a(sitePointer)+1)) cycle ! Did I violate a concentration restriction (*) ? 
                                                 !  ^         ! If so, don't go on with that labeling and rather cycle!
                                                 !  because the labeling (a) starts at 0 and goes to k-1
                                          ! (*) We only check for ">" because we're looking at ONE fixed concentration and 
                                          ! not a range. If THIS digit's concentration was too small, one of the concentrations
                                          ! of the other digits will be too large and we will catch that exception there.

   sitePointer = sitePointer + 1
   if(sitePointer>n*nD) sitePointer = n*nD
  !write(*,'(100i1)') a   
   if(is_valid_multiplicity(a,iConc)) then ! We have a valid labeling on the tree, mark it in the
      call generate_index_from_labeling(a,iConc,idxOrig) ! hash table and then mark the symmetry brothers
      if(lab(idxOrig)=='') then ! This labeling hasn't been generated yet (directly or by symmetry permutation)
         lab(idxOrig)='U'
         nUniq = nUniq + 1
         degeneracy_list(nUniq) = degeneracy_list(nUniq) + 1
         ! In the hash table, cross out the symmetrical duplicates
         do q = 2, nPerm
!             if(.not. is_valid_multiplicity(a(perm(q,:)),iConc)) cycle
             call generate_index_from_labeling(a(perm(q,:)),iConc,idx) ! permute the labeling then get new index
             if (.not. fixed_cells) then
                if (idx==idxOrig .and. q <= n) then                              ! This will happen if the coloring is superperiodic
                   degeneracy_list(nUniq) = degeneracy_list(nUniq) - 1           ! (i.e., non-primitive superstructure). The q=<n condition makes sure we are considering a
                   lab(idx)='N'                                                  ! "translation" permutation and not a rotation permutation (they're ordered in the
                end if                                                           ! list...and there are n. The first is the identity so skip that one.)
             end if
             ! This is a failsafe and should never trigger if the algorithm is properly implemented
             if (idx > nL) then
                write(*,'("iConc",100(i3,1x))') iConc
                write(*,'(100i1)') a
                write(*,'(100i1)') a(perm(q,:))
                print *,"idx",idx
                print *,"max expected",nL
                print *,"An index outside the expected range (i.e., outside the hash table) occurred in get_permutations_labeling"
                stop
             endif
             if(lab(idx)=='')then
                degeneracy_list(nUniq) = degeneracy_list(nUniq) + 1
                lab(idx)='D' ! Mark this labeling as a duplicate
             end if
          end do
       end if
    end if
 enddo

nUniq = count(degeneracy_list > 0.0001)
allocate(temp(nUniq) )
index = 1
do i = 1, size(degeneracy_list)
   if (degeneracy_list(i) > 0) then
      temp(index) = degeneracy_list(i)
      index = index + 1
   end if
end do
deallocate(degeneracy_list)
allocate(degeneracy_list(nUniq) )
degeneracy_list = temp
deallocate(temp)

! If there are no site restrictions, then the hash table is "minimal" and every entry should hove
! been visited. Double check if this is the case. Just another failsafe.
if(all(E==1) .and. any(lab=='')) then 
   print*,"There are no site restrictions and yet not every labeling was marked in generate_permutation_labelings"
   stop "There is a bug in generate_permutations_labeling in labeling_related.f90"
endif

CONTAINS
FUNCTION is_valid_multiplicity(labeling,concList)
logical is_valid_multiplicity
integer, intent(in) :: labeling(:)
integer, intent(in) :: concList(:)
integer i

is_valid_multiplicity = .true.
if (sum(concList)/=n*nD) stop "Something is strange in is_valid_multiplicity"
do i = 0, size(concList,1)-1 
   if(count(labeling==i)/=concList(i+1)) is_valid_multiplicity = .false.
enddo

END FUNCTION is_valid_multiplicity
END SUBROUTINE generate_permutation_labelings

!***************************************************************************************************
! This routine takes in a list of labels of the parent cell and and the number of different labels
! allowed on each site. It returns a "multiplier", and *expanded* versions of parLabel and parDigit
SUBROUTINE setup_mixed_radix_multiplier(n,k,parLabel,parDigit,label,digit,multiplier)
integer, intent(in) :: n,k ! The index (volume factor) of the supercell, k-nary case
integer, intent(in) :: parLabel(:,:), parDigit(:)
integer, pointer:: label(:,:), digit(:) ! n*longer than parLab/parDigit (INTENT(OUT))
integer, pointer:: multiplier(:)
integer i,j, nD, istat, ic

nD = size(parDigit) ! Size of the d-set n*nD is the total length of a labeling

!print *,associated(label),associated(digit),associated(multiplier)
if (associated(label)) deallocate(label)
if (associated(digit)) deallocate(digit)
if (associated(multiplier)) deallocate(multiplier)
allocate(label(k,n*nD),digit(n*nD),multiplier(n*nD),STAT=istat)
if (istat/=0) stop "Allocation failed in setup_mixed_radix_multiplier"

digit = (/((parDigit(j),i=1,n),j=1,nD)/) ! Repeat the digit ordinals across all places in the labeling
forall(j=1:k);label(j,:) = (/((parLabel(j,i),ic=1,n),i=1,nD)/); endforall ! Ditto for labels
multiplier = 0; multiplier(n*nD)=1
do i = n*nD-1,1,-1
   multiplier(i) = digit(i+1)*multiplier(i+1)
enddo
END SUBROUTINE setup_mixed_radix_multiplier

!***************************************************************************************************
! This routine takes a list of HNFs, and index, and an indexed list to output the labels for the
! HNFs matching the index. The input for the labelings is not a list of labelings but just the base
! 10 index for those that are unique. The base-10 index is converted to the base-k index and written
! in the output file. Re-expanding the base-10 index to base-k when it was already done once in the
! generate_unique_labelings routine is not efficient CPU-wise but save lots of memory since the
! labelings are never stored in memory except as a base-10 number.
SUBROUTINE write_labelings(k,n,nD,parLabel,parDigit,HNFi,HNFlist,SNFlist,L,fixOp, &
                           Tcnt,Scnt,Hcnt,permIndx,lm,equivalencies,hnf_degen,lab_degen,concVect)
integer, intent(in) :: k ! number of colors/labels
integer, intent(in) :: n, nD ! index (size of supercell), size of d-set
integer, intent(in) :: parLabel(:,:) ! The *labels* (index 1) for each d-vector (index 2) in the parent
integer, intent(in) :: parDigit(:) ! The *number* of labels allowed on each site of the parent cell 

integer, intent(in) :: hnf_degen(:), lab_degen(:)
integer, intent(in) :: HNFi ! Index in the permIndx corresponding to the current block of HNFs
integer, intent(in), dimension(:,:,:) :: HNFlist, SNFlist, L ! List of the HNFs, SNFs, L's. Need this just for the output
type(opList), intent(in) :: fixOp(:)
integer, intent(inout) :: Tcnt, Scnt, Hcnt ! counters for total number of labelings and number of this size and HNF running total 
integer, intent(in) :: permIndx(:)
character, intent(in) :: lm(:)
integer, optional, intent(in):: concVect(:)

integer nHNF ! Number of HNFs in the list that match the current block index, HNFi
integer, allocatable :: vsH(:), vsL(:) ! Vector subscript for matching the HNF index to the HNF list
integer nl ! Number of unique labelings
integer quot ! quotient for converting base-10 index to base-k labeling
integer iHNF, jHNF, il, i, ilab  ! counters
integer :: labeling(n*nD) ! base-k, n-digit number representing the labeling
integer(li) :: labIndx ! base-10 form of the labeling
integer status ! Allocation exit flag
integer ivsL
integer, pointer :: label(:,:)=>null(), digit(:)=>null(), multiplier(:)=>null() ! Need to convert base-10 back to labeling
logical conc_check
character(3) :: dummy
character(100) :: struct_enum_out_formatstring 


! Labeling Postprocessing data
integer, intent(in)  :: equivalencies(:) ! { full-dset member }: equivalent sites
integer              :: nAllD            ! size of full dset
integer, allocatable :: allD(:)          ! help array: (/ 1, 2, 3, ..., nAllD /)
integer, allocatable :: pplabeling(:)    ! postprocessed labeling
logical :: postprocessLabeling           ! do we need to postprocess labeling
integer, allocatable :: allD2LabelD(:)   ! { full-dset member }: respective d-vector ID in the labeling dset

! Postprocessing labelings: setup
nAllD = size(equivalencies)
allocate(allD(nAllD)); allD = (/ (i,i=1,nAllD) /)
allocate(allD2LabelD(nAllD));
! 1) Check whether we have to postprocess the labeling before writing it out
!    Postprocessing is needed if we do not want to enumerate all dset members of a primitive unit cell
!    due to some equivalencies. 
!    For example, in a 1x1 symmetric surface slab ( (*) denotes an atom ):
!
!      ------------------------------------------------ surface
!         (*)  topmost surface layer, dvector# 1
!         (*)  dvector# 2
!         (*)  dvector# 3
!         (*)  bottommost surface layer, dvector# 4
!      ------------------------------------------------ surface
!
!    the topmost and the bottommost atom should always have the same occupancy, as well as dvector 2
!    and dvector 3 should. You can therefore specify the following equivalency list:
!
!         equivalency of dvector# | 1 2 3 4
!         ---------------------------------   
!         equivalency list        | 1 2 2 1
!
!    which means that dvector# 1 and dvector# 4 have to have the same occupancy, they are equivalent
!    by enumeration. The same is true for dvector# 2 and dvector# 3
!
!    In this example, the enumeration code should only find enumerations of dvector# 1 and dvector# 2.
!    The occupations of dvector# 3 and dvector# 4 are then constructed in a postprocessing step. 
!    The postprocessing step takes the enumerated form (i.e. dvectors# 1 and 2, e.g. a labeling 0101 for
!    two unit cells) and tranforms it into a form that is valid for ALL dvectors, e.g. labeling 01010101 for
!    two unit cells).
!
postprocessLabeling = .not. (all(  abs( equivalencies-allD ) ==0))
allocate(pplabeling(n*nAllD))  ! this is ok whether we do postprocessing (nAllD>nD) or not (nAllD==nD)
! 2) if yes:
!    - prepare the postprocessed labeling (pplabeling)
!    - generate a map:  full dset -> enum dset
!      that tells me for a dset member of the full dset what dset member in the enumeration dset it
!      corresponds to
if (postprocessLabeling) then
  allD2LabelD = (/(count(pack(allD,allD<=equivalencies(i))==equivalencies),i=1,nAllD)/)
  ! this construction is best explained by an example:
  ! suppose we have a dset 1,2,3,4,5
  ! and the equivalent list is 1,4,4,4,5 (so, dset member 1,4,5 will be enumerated, having positions 1,2,3 in labelings)
  ! the map should accomplish: 1 -> 1, 2 -> 2, 3 -> 2, 4 -> 2, 5 -> 3
  ! first, the pack operation take only those in the dset <= equivalent point,
  ! then, the number of truly enumerated points is counted (truly enumerated points are points for which dset=equivalencies
endif

conc_check = .false.
if (present(concVect)) conc_check = .true.


!if (any(lm=='')) stop "Labeling index has unmarked entries"
nl = count(lm=='U'); nHNF = count(permIndx==HNFi)
allocate(vsH(nHNF),vsL(nl),STAT=status); if (status/=0) stop "Allocation failed in write_labelings: vsH, vsL"

! Packing...
vsH = pack((/(i,i=1,size(HNFlist,3))/), HNFi==permIndx); 
ivsL=0; do i=1,size(lm); if (lm(i)=='U') then; ivsL=ivsL+1; vsL(ivsL)=i; endif; enddo

! set up the multiplier, labels, digits, etc
call setup_mixed_radix_multiplier(n,k,parLabel,parDigit,label,digit,multiplier)

!print *,lm
!print *,nL
write(dummy,'(I3)') n*nAllD

struct_enum_out_formatstring = '(i11,1x,i9,1x,i7,1x,i8,1x,i8,1x,i11,1x,i3,2x,i4,2x,3(i2,1x),2x,6(i2,1x),2x,9(i4,1x),2x,'//trim(dummy)//'i1)'
do il = 1, nl ! Loop over the unique labelings
!   labIndx = vsL(il)-1 ! Get the base-10 index of the next unique labeling from the vector subscript array
   ! Now convert the base-10 number (labIndx) to the correct labeling
!   print *, labIndx, "CHECK THIS NUMBER-----------------------------------------------------------------------------------------------"
   if(conc_check) then
      labIndx = vsL(il)
      call generate_labeling_from_index(labIndx,concVect,labeling)
   else
      labIndx = vsL(il)-1
      do ilab=1,n*nD
        quot = labIndx/multiplier(ilab) ! How many times does k(i) divide the number
        labeling(ilab) = label(quot+1,ilab) ! The number of times, indicates the label number
        labIndx = labIndx - quot*multiplier(ilab) ! Take the remainder for the next step
      enddo
   endif
   if (postprocessLabeling) then
     ! see the comments at the beginning of the current routine
     call postprocess_labeling(n,nAllD,labeling,pplabeling,allD2LabelD) 
   else
     pplabeling = labeling ! nothing changes
   endif

   do iHNF = 1, nHNF ! Write this labeling for each corresponding HNF
      jHNF = vsH(iHNF) ! Index of matching HNFs
      ! check if concentrations of this labeling match the user specification:
      !GH if (check_labeling_numbers(pplabeling,number_ElementN,number_Range)) then
        Tcnt = Tcnt + 1; Scnt = Scnt + 1

        write(14,struct_enum_out_formatstring) &
             Tcnt, Hcnt+iHNF,hnf_degen(jHNF),lab_degen(il),lab_degen(il)*hnf_degen(jHNF),Scnt,n,size(fixOp(jHNF)%rot,3),SNFlist(1,1,jHNF),SNFlist(2,2,jHNF),SNFlist(3,3,jHNF),&
             HNFlist(1,1,jHNF),HNFlist(2,1,jHNF),HNFlist(2,2,jHNF),HNFlist(3,1,jHNF),HNFlist(3,2,jHNF),&
             HNFlist(3,3,jHNF),transpose(L(:,:,jHNF)),pplabeling!,lab_degen(il), hnf_degen*lab_degen(il)   
      !GH endif
   enddo ! loop over HNFs
enddo ! loop over labelings
Hcnt = Hcnt + nHNF 

contains

! Purpose: take an enumeration labeling (for selected, non-equivalent (by enumeration) dvectors) and
!          construct the full labeling for all dvectors. It makes sure that two dvectors in the same
!          primitive unit cell of the parent lattice get the SAME labeling always.
! See also comments at the beginning of write_labelings
subroutine postprocess_labeling(nUC,nAllD,oldlabeling,newlabeling,newD2oldD)
integer, intent(in) :: nUC, nAllD          ! number of unit cells, number of d-vectors in the new labeling
integer, intent(in) :: oldlabeling(:)      ! the old labeling
integer, intent(out):: newlabeling(:)      ! the wanna-be new labeling
integer, intent(in) :: newD2oldD(:)        ! { new D# }: a map  newD -> oldD

integer :: newlab_pos, oldlab_pos
integer :: iD,iUC

do iD=1,nAllD
  do iUC=1,nUC
    newlab_pos = (iD-1)*nUC + iUC               ! position in the new labeling
    oldlab_pos = (newD2oldD(iD)-1)*nUC + iUC    ! corresponding position in the old labeling
    newlabeling(newlab_pos) = oldlabeling(oldlab_pos)
  enddo
enddo

end subroutine postprocess_labeling

ENDSUBROUTINE write_labelings


!***************************************************************************************************
! This routine takes a number (an index) and the number of labels and the number of each type of
! label (i.e., the concentration) and generates the labeling that corresponds to the index. 
SUBROUTINE generate_labeling_from_index(INindx,conc,l)
integer, intent(in)   :: conc(:)
integer,intent(out)   :: l(:)
integer(li),intent(in):: INindx

integer(li)               :: indx
integer(li), dimension(size(conc)) :: x
integer,     dimension(size(conc)) :: m, j
integer  iK, k, ij, n, slotsRem
integer, allocatable :: vsBits(:), vsLabels(:) ! Vector subscripts for masking elements to be updated
integer, allocatable :: bitString(:)


indx = INindx - 1 ! The algorithm uses a 0..N-1 indexing so shift by one 
k = size(conc)
n = sum(conc)
slotsRem = n
l = -1

call get_Xmj_for_labeling(indx,conc,x,m,j)
!print *, "INDEX................", indx
!print *, "CONC...................", conc
!write(*,'("X...............   ",20(i9,1x))') x
!write(*,'("M..................  ",20(i2,1x))') m
!write(*,'("J.................      ",20(i2,1x))') j
   !print *,"calling generate labeling"
do iK = 1, k
   if (m(iK)==0) cycle  ! If there aren't any slots occupied by this label then cycle (avoid segfault in vsBits)
   allocate(bitString(m(iK)))
   call generate_BitStringEqv(x(iK),m(iK),j(iK),bitString)
   allocate(vsBits(j(iK)),vsLabels(slotsRem))
  
   vsLabels = pack((/(ij,ij=1,n)/),l==-1)
   vsBits   = pack((/(ij,ij=1,m(iK))/),bitString==1)
   l(vsLabels(vsBits)) = iK - 1 ! Offset to start labels at zero
   deallocate(vsBits,vsLabels,bitString)
   slotsRem = slotsRem - conc(iK)
enddo
!write(*,'(20(i1,1x))') l
if(any(l==-1)) stop "ERROR: Incomplete labeling was generated from the index: generate_labeling_from_index"
END SUBROUTINE generate_labeling_from_index

!***************************************************************************************************
! This routine takes a labeling and generates the index. 
SUBROUTINE generate_index_from_labeling(l,conc,idx)
integer, intent(in)     :: l(:), conc(:)
integer(li), intent(out) :: idx

integer C(size(conc)), X(size(conc))
integer iK, n
integer(li) p

n = size(conc)

!print *,"shape conc",shape(conc)
!print *,"conc in generate indxe: ",conc
call get_Cs(conc,C)
!print *, C, "Cs<<<-------------"
call get_Xs_from_labeling(conc,l,X)
!print *, X, "Xs.................."
p = 0
do iK = n, 1, -1
   p = p*C(iK)
   p = p + X(iK)
enddo
idx = p + 1

END SUBROUTINE generate_index_from_labeling

!***************************************************************************************************
! This routine take a list of concentrations and returns the "C" values (see Rod's write-up)--- the
! divisors that are needed to turn a labeling into an index
SUBROUTINE get_Cs(conc,C)
integer, intent(in) :: conc(:)
integer, intent(out):: C(:)
integer n, nLeft, iK

nLeft = sum(conc)

n = size(conc)
do iK = 1, n
   C(iK) = binomial(nLeft,conc(iK)) 
   nLeft = nLeft - conc(iK)
enddo
END SUBROUTINE get_Cs

!***************************************************************************************************
! 
SUBROUTINE get_Xs_from_labeling(conc,l,X)
integer, intent(in) :: conc(:)
integer, intent(in) :: l(:) ! the current labeling
integer, intent(out):: X(:)

integer n, iK, xTemp, iM, nLeft
integer, allocatable :: mask(:)

n = size(conc)
nLeft = sum(conc)

do iK = 1, n
!   print *,"nLeft: ",nLeft
   allocate(mask(nLeft))
   mask = 0
!   write(*,'("pack l: ",20(i2,1x))') pack(l,l>=iK-1)
   where(pack(l,l>=iK-1)==iK-1)
!   where(l==iK-1)
      mask = 1
   end where
!   write(*,'(20(i1,1x))') mask
   xTemp = 0
   do iM = 1, nLeft
      if (mask(iM)==0) then!&
         xTemp = xTemp + binomial(nLeft - iM, count(mask(iM:)==1)-1) 
!         write(*,'("top ",i5)')nLeft - iM
!         write(*,'("bot ",i5)') count(mask(iM:)==1)-1
!         write(*,'("binm ",i9)') binomial(nLeft - iM, count(mask(iM:)==1)-1)
      endif
   enddo
   X(iK) = xTemp
   nLeft = nLeft - conc(iK)
   deallocate(mask)
enddo
!write(*,'("Xs: ",20(i5,1x))') X
END SUBROUTINE get_Xs_from_labeling

!***************************************************************************************************
! Generate the bit-string equivalent of the matches and non-matches in a labeling for a given
! label. This creates a "mask" that is used to populate the labeling with the given label, placing
! the labels in the appropriate locations.
SUBROUTINE generate_BitStringEqv(idx,m,j,mask)
integer(li),intent(in):: idx
integer, intent(in)   :: m, j
integer, intent(out)  :: mask(m)

integer i,t,x,bnml
mask = -1
x = idx
i = m
t = j
do while (i>=1)
   bnml = binomial(i-1,t-1)
   if (bnml <= x) then
      mask(m-i+1) = 0
      x = x - bnml
   else
      mask(m-i+1) = 1
      t = t - 1
   endif
   i = i - 1
enddo
if(any(mask==-1)) stop "routine generate_BitStringEqv has a bug. Not all slots filled"
END SUBROUTINE generate_BitStringEqv

!***************************************************************************************************
! This routine generates the X's, m's, and j's for a labeling (see Rod's write-up) but the labeling
! specified by its index, not one given explicitly. These three things are passed into
! generate_BitStringEqv for each label. The latter returns a mask for each label that can be used to 
! populate the labeling for a given index.
SUBROUTINE get_Xmj_for_labeling(idx,conc,x,m,j)
integer(li), intent(in) :: idx
integer, intent(in)     :: conc(:)
integer(li), intent(out):: x(:)
integer,     intent(out):: m(:), j(:)
! x is the index of the i-th label among the remaining slots as we loop over labels
! m is the number of remaining slots (slots for i-th label and > i-th labels)
! j is the number of the current label

integer k, n, iL
integer(li) :: quot
integer c

quot = idx
j = conc
k = size(conc)
n = sum(conc)
do iL = 1, k
   m(iL) = n
   n = n - conc(iL)
   c = binomial(m(iL),j(iL))
   x(iL) = mod(quot,c)
   quot = quot/c
enddo

END SUBROUTINE get_Xmj_for_labeling
!***************************************************************************************************
! This routine takes in a list of HNFs and a list of rotations (orthogonal transformations) and
! computes the permutations of the labels effected by the rotation. Then the HNFs are grouped into
! categories according to which permutations are applicable.
SUBROUTINE make_label_rotation_table(HNF,L,A,R,G,d, eps, lrTab,lrIndx)
integer, intent(in) :: HNF(:,:,:), L(:,:,:) ! HNFs, set of rotations, left SNF transformations
type(opList), intent(in) :: R(:)
real(dp), intent(in) :: A(3,3) ! Lattice vectors of the parent lattice
integer, intent(in) :: G(:,:) ! The translation group for this SNF
integer, intent(out) :: lrTab(:,:,:) ! Table of the label rotation permutations (perm #, label, lrlist#)
integer, intent(out) :: lrIndx(:) ! Index for permutations list associated with each HNF
integer, intent(in) :: d(3) ! Diagonal elements of the SNF

integer iH, iR, iq, i, j, k, ilq, iM, iHindx, il ! Loop counters
integer nH, nR, n, nlq, nq, status, b, nM(1)
logical unique, err ! flag for identifying new permutation lists, error flag
integer, allocatable :: tlr(:,:) ! temporary list of label rotations for current HNF
real(dp), dimension(3,3) :: T, A1, A1inv, Ainv ! Matrices for making the transformation
integer :: Gp(size(G,1),size(G,2))
integer, allocatable :: trivPerm(:), tM(:,:,:)
real(dp) eps
integer, dimension(3,3) :: M

nH = size(HNF,3) ! Number of HNFs
! Find the maximum number of symmetries for the list of HNFs
nR = 48 ! debug
n = determinant(HNF(:,:,1)) ! Index of the current superlattices
nlq = 0 ! Number of permutation lists that are unique
allocate(tlr(nH,nR),trivPerm(n),STAT=status)
if (status/=0) stop "Trouble allocating tlr, tlrq, trivPerm in make_label_rotation_table"
trivPerm = (/(i,i=1,n)/); tlr = 0;
allocate(tM(3,3,96),STAT=status) ! Why the 96? What's the appropriate number here? >48 but what?
if (status/=0) stop "Trouble allocating tM in make_label_rotation_table"
lrTab = 0; tM = 0; lrIndx = 0

nq = 0; ilq = 0 ! Number of unique transformation matrices (M's), number of unique lists of M's
call matrix_inverse(A,Ainv,err)  ! Need A^-1 to form the transformation
do iH = 1, nH   ! Make a list of permutations for this HNF
   ! First find the permutation on the group by each rotation
   A1 = matmul(L(:,:,iH),Ainv)
   call matrix_inverse(A1,A1inv,err)
   iHindx = 0 ! Keep track of the number of transformations that apply to each HNF
   do iR = 1, size(R(iH)%rot,3) ! Loop over all rotations
      T = matmul(A1, matmul(R(iH)%rot(:,:,iR),A1inv))  ! This is the transformation
      if (.not. equal(T,nint(T),eps)) &
         stop 'ERROR: make_label_rotation_table: Transformation is not integer'
      M = modulo(nint(T),spread(d,2,3))
      ! See if this transformation matrix M is unique
      unique = .true.
      do iq = 1, nq
         if (all(tM(:,:,iq) == M)) then; unique = .false.; exit; endif
      enddo
      if (unique) then
         nq = nq + 1 ! Update number of unique matrices found
         tM(:,:,nq) = M ! Store new matrix in temp list of M's
         iq = nq ! Which matrix in the list is this one? Store in iq
      endif
      if (.not. any(tlr(iH,:)==iq)) then ! This M is not yet associated with this HNF
         iHindx = iHindx + 1             ! so store it in the next place in the list
         tlr(iH,iHindx) = iq
      endif
   enddo ! Loop over rotations
   ! Check if the list of M's for this HNF is unique, or if it is already in the list of lists
   ! First let's sort the list so that the comparisons are robust. (Insertion sort, fine for short lists)
   sort: do j = 2, count(tlr(iH,:)/=0) ! Loop over each non-zero element in the list
      b = tlr(iH,j) ! Temp storage
      k = j-1 ! index pointer to preceding element
      do while(k>0)
         if (tlr(iH,k)<=b) exit
         tlr(iH,k+1)=tlr(iH,k)
         k = k-1
      enddo
      tlr(iH,k+1)=b
   enddo sort ! <<< End sorting
   ! Fail safe on sorting
   do j = 2, count(tlr(iH,:)/=0); if (tlr(iH,j)<tlr(iH,j-1)) stop "Sorting failed";enddo

   ! Now check to see if we have a unique list of M's
   unique = .true.
   do iM = 1, iH
      if (all(tlr(iH,:)==tlr(iM,:)) .and. lrIndx(iM)/= 0) then ! the list has already been found for another HNF
         lrIndx(iH) = lrIndx(iM); unique = .false.; exit; endif
   enddo
   if (unique) then; ilq = ilq + 1; lrIndx(iH) = ilq; endif ! ilq is the number of unique *lists*
enddo

! <<< Make the permutation lists >>>
! We now know which group of permutations is applicable to each HNF. So we just make the lists of
! permutations (right now we just have a list of matrices) and pass that back out
do il = 1, ilq ! Loop over all lists
   ! What is the first list in tlr that corresponds to il?
   nM = minloc(lrIndx,(lrIndx==il))
   do iM = 1, count(tlr(nM(1),:)/=0)
      Gp = matmul(tM(:,:,tlr(nM(1),iM)),G)
      do i=1,3; Gp(i,:) = modulo(Gp(i,:),d(i));enddo  ! Can you do this without the loop, using vector notation?
      do i = 1, n ! Loop over each element of Gp and find its corresponding element in G
         do j = 1, n
            if (all(Gp(:,j)==G(:,i))) then ! the two images are the same for the i-th member
               lrTab(i,iM,il) = j
            endif
         enddo
      enddo
      if (any(lrTab(1:n,iM,il)==0)) then
         stop "Transform didn't work. Gp is not a permutation of G"
      endif
   enddo
enddo

ENDSUBROUTINE make_label_rotation_table

!***************************************************************************************************
! This routine takes two lists of integer sequences and compares them to see if they are the
! same. The input lists are assumed to contain unique entries and perhaps be padded with zeros.
FUNCTION lists_match(list1, list2)
integer, intent(in) :: list1(:,:), list2(:,:) 
logical lists_match, rowmatch
integer nL ! length of each list
integer i,j
lists_match = .false.; rowmatch = .false.
nL = size(list1,2) 
do i = 1, nL
   if (all(list1==list2)) then; rowmatch = .true.; exit; endif
   rowmatch = .false.
   do j = 1, nL
      if (all(list1(:,i)==list2(:,j))) then; rowmatch = .true.; exit; endif
   enddo
   if (.not. rowmatch) exit
enddo
if (rowmatch) lists_match = .true.
ENDFUNCTION lists_match

!***************************************************************************************************
! This function compares a proposed labeling to the list of allowed labels on each site. If any
! label is present "illegally" on one site, then the function is false. This routine is needed
! because if different labels are allowed on different sites, the symmetry operations of the
! underlying parent lattice (where all sites are considered equivalent) can permute a legal labeling
! to an illegal one by permuting one label (on an allowed site) to another site where it is not
! allowed. (GLWH see moleskine 10/9/2009)
FUNCTION labeling_is_legal(labeling,siteLabels,digitN)
logical             :: labeling_is_legal
integer, intent(in) :: labeling(:), siteLabels(:,:), digitN(:)
integer iL, nL

nL = size(labeling)
labeling_is_legal = .true.
do iL = 1, nL ! Loop over all labels that are possible
   if (all(labeling(iL)/=siteLabels(:digitN(iL),iL))) then ! no matching label for this digit
      labeling_is_legal = .false.
      exit ! if there isn't a match in just one digit, illegal labeling
   endif
enddo

ENDFUNCTION labeling_is_legal

!****************************************************************************************************
! This routine takes in the permutations effected by both translation and by rotations that fix the
! superlattice and generates all labelings that are unique. It also removes super-periodic labelings
! (non-primitive superstructures). If the "full" variable is false, it also removes
! "label-permutation" duplicates---labelings that are not unique when the labels themselves (not
! their positions) are permuted (e.g., 00111 <--> 11000).  The basic idea of the routine is to run
! like an "odometer", generating all numbers (base k) from 0 to k^n - 1, and  then use rotation and
! translation permutations to eliminate labelings that represent equivalent superstructures.
!
! Got rid of the old comments from the original counter (that didn't
! allow for different labels on different sites) at svn revision #191
! (GLWH Dec 2011)
SUBROUTINE generate_unique_labelings(k,n,nD,perm,full,lab,parLabel,parDigit,degeneracy_list,fixed_cells)
integer, intent(in) :: k ! Number of colors/labels
integer, intent(in) :: n ! Index of the superlattice
integer, intent(in) :: nD ! Number of sites in the basis of the parent lattice (size of d-set)
integer, intent(in) :: perm(:,:) ! list of translation and rotation permutations
character, pointer :: lab(:)     ! Array to store markers for every raw labeling
! I=>incomplete labeling, U=>unique, D=>rot/trans duplicate, N=>non-primitive, E=>label exchange
! Need to pass lab out to write out the labelings
logical, intent(in) :: full ! specify whether the full labelings list should be used or not
integer, intent(in) :: parLabel(:,:) ! The *labels* (index 1) for each d-vector (index 2) in the parent
integer, intent(in) :: parDigit(:) ! The *number* of labels allowed on each site of the parent cell 
integer, pointer :: degeneracy_list(:)
logical, intent(in) :: fixed_cells ! Enumeration for user-specified cells           

integer j ! Index variable (place index) for the k-nary counter
integer(li) ic
integer i, q ! loop counters, index variables
integer(li) nexp ! number of raw labelings that the k-ary counter should generate
integer nl ! number of labels in each labeling (i.e., determinant size*d-set size)
integer(li) idx ! the base 10 equivalent of the current base k labeling
integer a(n*nD), b(n*nD) ! the "odometer"; label-permuted odometer
integer il ! loop counter over each digit in a labeling
integer digCnt(n*nD) ! Ordinal counter for each place in the labeling (a mixed-radix number)
integer digit(n*nD) ! Each entry is the number of labels in each place
integer label(k,n*nD) ! Same as parLabel but repeated n times
integer(li) multiplier(n*nD) ! place values for each digit. k^(i-1) for the i-th digit for "normal"
!  base-k numbers. More complicated for mixed radix case.
integer c(0:k-1) ! running sum (count) of the number of each label type 
integer id, iq ! Counter for labels that are duplicates, for those unique
integer, pointer :: labPerms(:,:) ! List of permutations of the k labels
integer :: nsp ! Number of superperiodic labelings
integer :: np, ip, nPerm, status ! Loops over label exchang permutations, number of labeling permutatations, allocate error flag
integer, allocatable :: degen(:),temp(:) ! keep track of degeneracy for each structure.
integer nUniq


lab => null()

nl = n*nD

!< Set up the number of expected labelings
nexp = product(parDigit)**int(n,li)  ! should be the same as k**nl when all labels are on all sites
if (nexp<0) stop "ERROR in generate_unique_labelings: integer overflow of variable nexp."

!if (associated(lab)) deallocate(lab)
allocate(lab(nexp),STAT=status)
if(status/=0) stop "Failed to allocate memory for 'lab' in generate_unique_labelings"

! Initialize the counter and ordinal arrays for the mixed-radix counter
digit = (/((parDigit(j),i=1,n),j=1,nD)/) ! Repeat the digit ordinals across all places in the labeling
digCnt = 1 ! Initialize each place to the first label ("lowest" digit)
! "label" stores a list of allowed labels. Each column shows the allowed
! labels on each site. The number of rows is k (number of colors---
! e.g., binary, ternary, etc.). If a label (or labels) is not allowed
! on a particular site, then the end of the column will be padded with
! -1.
! For example, consider a 2-lattice and n=2. If k=4 (quaternary) and
! labels 0,1,3 are allowed on site 1 in the parent and labels 1,2,3
! are allowed on the second site in the parent cell, then the table
! "label" will contain:
!    0  0  1  1
!    1  1  2  2
!    3  3  3  3
!   -1 -1 -1 -1
forall(j=1:k);label(j,:) = (/((parLabel(j,i),ic=1,n),i=1,nD)/); endforall

! Stores the number of each label in the current labeling. Initialized here.
forall(j=0:k-1); c(j) = count(label(1,:)==j); endforall


a = label(1,:)
multiplier = k**(/(i,i=nl-1,0,-1)/) ! The counter; multiplier to convert to base 10

!< Set up a new multiplier
multiplier = 0; multiplier(nl)=1
do i = nl-1,1,-1
   multiplier(i) = digit(i+1)*multiplier(i+1)
enddo

lab = ''; iq = 0  ! Index for labelings; number of unique labelings
if (k>12) stop "Too many labels in 'generate_unique_labelings'"
nPerm = size(perm,1)

np = factorial(k) ! Number of permutations of labels (not labelings)

call get_permutations((/(i,i=0,k-1)/),labPerms) 
!call count_full_colorings(k,d,cnt,full) ! Use the Polya polynomial to count the labelings
!call make_translation_group(d,trgrp) ! Find equivalent translations (permutations of labelings)

ic = 0; c = 0; c(0) = nl ! Loop counter for fail safe; initialize digit counter
! In the recent version of multienum.x, we can't assume that the label of the first type appears on
! all sites. So this naive initialization doesn't work any more. Instead we need to count how many
! times each label appears in the starting labeling. I think that we can just look through the first
! row of the parLabel array and count how many times each label shows up.
do ic = 0, k-1
   c(ic) = count(label(1,:)==ic)
enddo

allocate(degeneracy_list(nexp) )
degeneracy_list = 0
if (sum(c)/=nl) stop "ERROR: initialization of the 'c' counter failed in generate_unique_labelings"

ic = 0
nUniq = 0
do; ic = ic + 1
   if (ic > nexp) exit ! Fail safe
   idx = sum((digCnt-1)*multiplier)+1
   if (any(c==0)) then ! Check to see if there are missing digits
      id = id + 1; ! Keep track of the number of incomplete labelings
      if (lab(idx)=='' .and. .not. full) then ! If it isn't marked and we want a partial list, mark it as "incomplete"
         lab(idx) = 'I';    ! Could mark its brothers too...
      endif
   endif
   if (any(c<0)) stop "Bug in the digit counter in generate_unique_labelings: negative digit count!"
   ! If this label hasn't been marked yet, mark it as unique, 'U'
   ! and mark its duplicates as 'D'
   if (lab(idx)=='') then
      lab(idx) = 'U'
      nUniq = nUniq + 1
      degeneracy_list(nUniq) = 1
      ! Is the first permutation in the list guaranteed to be the identity? We need to skip the identity
      do q = 2,nPerm ! Mark duplicates and eliminate superperiodic (non-primitive) colorings
         if (.not. labeling_is_legal(a(perm(q,:)),label,digit)) then
            cycle
         endif
         idx = sum((digCnt(perm(q,:))-1)*multiplier)+1
         if (.not. fixed_cells) then
            ! This will happen if the coloring is superperiodic
            ! (i.e., non-primitive superstructure). The q=<n condition makes sure we are considering a
            ! "translation" permutation and not a rotation permutation (they're ordered in the
            ! list...and there are n. The first is the identity so skip that one.)
            if (q<= n .and. idx==ic) then
               degeneracy_list(nUniq) = degeneracy_list(nUniq) - 1
               lab(idx)='N'
            end if
         end if
         if (idx > nexp) then
            print *, "Index of permuted labeling is outside the range"
            write(*,'("original labeling ",20i1)') a
            write(*,'("permuted labeling ",20i1)') a(perm(q,:))
            write(*,'("perm ",i2,":",4i2)') (i,perm(i,:),i=1,nPerm)
            write(*,'("Index: ",i4)') idx
            write(*,'("Max expected index: ",i4)') nexp
            write(*,'("Multiplier: ",20(i3,1x))') multiplier
            stop
         endif

         if (lab(idx)=='') then
            degeneracy_list(nUniq) = degeneracy_list(nUniq) + 1
            lab(idx) = 'D'  ! Mark as a duplicate
         endif
      enddo
      if (.not. full) then ! loop over the label-exchange duplicates and mark them off.
         do q = 1,nPerm ! Loop over all possible permutations. (should this loop start at 1? I think so...)
            do ip = 2,np ! Loop over all permutations of the labels (stored in 'labPerms'). Start at
               ! 2 since we want to skip the identity.
               do il = 1, nl ! For each digit in the labeling, permute the label (label exchange)
                  b(il) = labPerms(a(il)+1,ip)
               enddo
               if (.not. labeling_is_legal(b,label,digit)) then
                  cycle
               endif
               idx = sum(b(perm(q,:))*multiplier)+1
               if  (lab(idx)=='') then
                  degeneracy_list(nUniq) = degeneracy_list(nUniq) + 1
                  lab(idx) = 'E' ! Only marks of a label-exchange duplicate if it's
               endif
               ! not otherwise marked
            enddo
         enddo
      endif ! end block to remove label exchange duplicates
   endif
   

! "c" counts the number of labels of each kind across the entire labeling. Need this for "partial"
! lists that have label-exchange duplicates removed.
! "a" is the reading on the odometer
! "digCnt" is the ordinal counter of each digit (i.e., place) in the mixed-radix number (labeling)
   ! Advance the base-k, n*nD-digit counter and keep track of the # of each digit
   j = nl ! Reset the digit index (start all the way to the right again)
   do ! Check to see if we need to roll over any digits, start at the right
      if (digCnt(j) /= digit(j)) exit ! This digit not ready to roll over, exit the loop and advance digit
      a(j) = label(1,j) ! Reset the j-th place to the first digit
      digCnt(j) = 1 ! Reset the ordinal digit count for the j-th place to one
      c(label(digit(j),j)) = c(label(digit(j),j)) -1 ! Reduce the count of digits of that type
      c(label(1,j)) = c(label(1,j)) + 1  ! So we pick up another "zero" in the current place 
      j = j - 1;       ! Look at the next (going leftways) digit
      if (j < 1) exit  ! If we updated the leftmost digit then we're done
   enddo
   if (j < 1) exit ! We're done counting (hit all possible numbers), exit
   digCnt(j) = digCnt(j) + 1
   a(j) = label(digCnt(j),j)   
   c(a(j)) = c(a(j)) + 1     ! Add 1 to the number of digits of the j+1-th kind
   c(label(digCnt(j)-1,j)) = c(label(digCnt(j)-1,j)) - 1 ! subtract 1 from the number of digits of the j-th kind
   if (sum(c) /= nl .and. .not. full) stop 'counting bug'
enddo
nUniq = count(degeneracy_list > 0.0001)
allocate(temp(nUniq))
idx = 1
do i = 1, size(degeneracy_list)
   if (degeneracy_list(i) > 0) then
      temp(idx) = degeneracy_list(i)
      idx = idx + 1
   end if
end do
deallocate(degeneracy_list)
allocate(degeneracy_list(nUniq) )
degeneracy_list = temp
deallocate(temp)
if (ic /= nexp) then
   print *, 'number of permutations counted', iC
   print *, 'number expected', nexp
   stop 'Bug: Found the wrong number of labels!'
endif
if (any(lab=="")) stop "Not every labeling was marked in generate_unique_labelings"
nsp = count(lab=="N") 
!write(*,'(i3,2x,i10,2x,i10,2x,f9.6)') n,nsp,ic,nsp/real(ic,dp)
END SUBROUTINE generate_unique_labelings

 
!**************************************************************************************************
! Takes the length of three cyclic group and constructs the member list so that
! the permutations can be determined. Each member has three components, corresponding to the
! entries for each of the three cyclic groups. 
SUBROUTINE make_member_list(n,p)
! INPUT
integer, intent(in)  :: n(3)! Diagonal elements of the SNF
! OUTPUT
integer, pointer :: p(:,:)  ! List of members of the translation group

integer im, status  ! loop over members, allocate status flag
!if (associated(p)) deallocate(p)
allocate(p(3,product(n)),STAT=status)
if(status/=0) stop "Allocation of 'p' failed in make_member_list"
p = 0
do im = 2,product(n)  ! Loop over the members of the translation group
   p(:,im) = p(:,im-1) ! Start with the same digits as in the previous increment
   p(3,im) = mod(p(3,im-1)+1,n(3))  ! Increment the first cyclic group
   if (p(3,im)==0) then             ! If it rolled over then 
      p(2,im) = mod(p(2,im-1)+1,n(2))! increment the next cyclic group
      if (p(2,im)==0) then          ! If this one rolled over too
         p(1,im) = mod(p(1,im-1)+1,n(1)) ! Then increment the third one
      endif
   endif
enddo
ENDSUBROUTINE make_member_list

!***************************************************************************************************
! This routine finds all the permutations of the group members that leave the decoration unchanged.
! Essentially we are finding a list of mappings: add to the group one of the members of the group
! to get another member of the group. This list of mappings is the list of labeling (coloring) 
! permutations that leave the superstructure unchanged.
SUBROUTINE make_translation_group(d,trans)
integer, intent(in) :: d(3) ! members of the group, diagonal elements of SNF
integer, pointer :: trans(:,:) ! Translations that leave the superstructure unchanged

integer n, im,i, j, status
integer tg(3,d(1)*d(2)*d(3)) ! Temporary storage for the translations
integer, pointer :: m(:,:) => null() ! List of group members

! Get a list of group members; essentially a mixed-radix, 3 digit counter
call make_member_list(d,m)
n = product(d) ! Number of elements in each permutation group
if (associated(trans)) deallocate(trans)
allocate(trans(n,n),STAT=status)
if(status/=0) stop "Allocation of 'trans' failed in make_translation_group"

do im = 1, n
   ! add the im-th element of the group to every element in the group, mod d
   forall(i=1:size(tg,2)); tg(:,i) = mod(m(:,im) + m(:,i),d);end forall
   ! Find the index of the group member in the translated group
   do i = 1,n ! This approach is an N^2 loop. Can this be improved? Does it matter? I don't think so N is small
      do j = 1,n
         if (all(tg(:,i)==m(:,j))) then ! the two members are equal
            trans(im,i) = j             ! Save the index and exit the loop
            exit; endif; enddo; enddo
   if (sum(trans(im,:)) /= (n*n+n)/2) stop "*** Bug in group generator! ***"
enddo
END SUBROUTINE make_translation_group

!*******************************************************************************
! This routine calculates the result of the counting polynomial to find the total number
! of unique colorings of "n" things using "k" colors. The outer loop is for inclusion/exclusion
! so that colorings that don't use each color at least once are removed from the counting. The use
! of every color at least once is what is meant by a "full" coloring
SUBROUTINE count_full_colorings(k,d,count,full)
integer, intent(in) :: k, d(3)  ! Number of colors, diagonal entries of the Smith Normal Form matrix
integer, intent(out) :: count   ! Number of unique, full colorings
logical, intent(in) :: full ! Use a full list? (including incomplete labelings)
integer x1,x2,x3 ! Counters over d1,d2,d3, in the triple sum
integer p        ! Counter over number of terms in the exclusion/inclusion counting
integer m, tc    ! Color index (counter), intermediate (temporary) counter
integer n        ! Number of elements to be colored
m = k; count = 0
n = product(d)
if (full) then   ! The number of labelings for a full list is trivial, just k^n
   count = k**n
else  ! For a partial list (incomplete labelings not included) things are slightly more complicated
   do p = 0,m-1  ! Loop over each term in the exclusion/inclusion expression
      tc = 0
      do x1 = 1,d(1)  ! Loop over the triple sum
      do x2 = 1,d(2)
      do x3 = 1,d(3)
         tc = tc + (m-p)**gcd(d(1)*d(2)*d(3), x1*d(2)*d(3), d(1)*x2*d(3), d(1)*d(2)*x3)
      enddo; enddo; enddo
      count = count + (-1)**p*nchoosek(m,p)*tc
   enddo
   count = count/n
endif

ENDSUBROUTINE count_full_colorings

!***************************************************************************************************
! This is a sketch of the permutations labeling routine for enumerating permutations when the
! partitions possible labelings of the d-vectors in the parent cell are disjoint sets.
! This routine is just a re-write of the generate_permutations_labelings routine
!  !o> indicates "old" code or comments, !> indicates modified or new code or comments.

SUBROUTINE generate_disjoint_permutation_labelings(k,n,nD,perm,lab,iConc,parLabel,parDigit)
integer, intent(in) :: k ! Number of colors/labels
integer, intent(in) :: n ! Index of the superlattice
integer, intent(in) :: nD ! Number of sites in the basis of the parent lattice (size of d-set)
integer, intent(in) :: perm(:,:) ! list of translation and rotation permutations
character, pointer :: lab(:) ! Array to store markers for every raw labeling
! I=>incomplete labeling, U=>unique, D=>rot/trans duplicate, N=>non-primitive, E=>label exchange
! Need to pass lab out to write out the labelings
!integer, intent(in) :: iConc(:) !> concentration; the numerator of each rational number that is the
!                                !> concentration for each label (denominator is n*nD), length is k
integer :: iConc(:) !!> concentration; the numerator of each rational number that is the

!> Now, this will be the concentration "numerators" for subsets, not for labels
integer, intent(in) :: parLabel(:,:) ! The *labels* (index 1) for each d-vector (index 2) in the parent
integer, intent(in) :: parDigit(:) ! The *number* of labels allowed on each site of the parent cell 

integer, allocatable:: E(:,:) ! A matrix of 1's and 0's, indicating site-restrictions
! One row for each site in the supercell, one column for each color (label)
integer nL, status !  number of perumations (labelings)
integer q, nPerm ! loop counter for symmetry permutations
integer(li) idxOrig, idx  ! Index of unpermuted labeling, Index of a permuted labeling
integer a(n*nD) ! The current labeling depicted as a list of integers
integer ik, iD ! Loop counters for colors and sites in the supercell
integer sitePointer ! Marks the location of the current digit that is advancing
logical flag ! Use this to exit the loops once we have traversed the entire tree

integer digCnt(n*nD)  !!> Ordinal counter for each place in the labeling (a mixed-radix number)
integer digit(n*nD)   !!> Each entry is the number of labels in each place
integer label(k,n*nD) !!> Same as parLabel but repeated n times
integer i, j, ic  !!> loop variables

lab => null()

!o>nL = multinomial(iConc) ! The hash table is "full size" even if
                         !o> site-restrictions will reduce the size of the list
!> The size of the hash table will be smaller than the multinomial over the concentration divisions
!> of the labels but will be 
!> *** Might be easier to read if iConc was renamed to something that indicated sets... ****

print *,"Change iConc declaration back when done"
iConc = (/2,2,0,0/)
!if (size(iConc)/=nSets) stop "ERROR: number of disjoint subsets does not match entries in iConc"
nl = multinomial(iConc)

allocate(lab(nL),STAT=status)
if(status/=0) stop "Allocation of 'lab' failed in generate_disjoint_permutation_labelings"
lab = ""
nPerm = size(perm,1)

! Initialize the mask (E) used to prune the tree to meet site restrictions 
!o> Still need this to have k columns, and not nSets columns
allocate(E(n*nD,k))
E = 0
do ik = 1, k; do iD = 1, n*nD
   if (any(parLabel(:,(iD-1)/n+1)==ik-1)) then ! this label is allowed on this site
      E(iD,ik) = 1
   end if
end do; end do
! Write a file containing the mask for site restrictions
open(22,file="debug_site_restrictions.out",access="append")
write(22,'("site #   parent site #        Mask")') 
do iD = 1, n*nD
   write(22,'(i4,8x,i3,10x,10(i2,1x))') iD,(iD-1)/n+1,E(iD,:)
end do; write(22,*); close(22)

!o> Set up some tables to keep track of the labels on each site
!o> "digit" keeps track of how many labels are allowed on each site in the supercell.
digit = (/((parDigit(j),i=1,n),j=1,nD)/) 
!o> "digCnt" keeps track of where each "place" in the labeling is. Thinking of it as a type of
!o> odometer, "digCnt" keeps track of where each "wheel" is
digCnt = 1   !!> Initialize each site "wheel" to the first label ("lowest" digit)
digCnt(1) = 0!!> except the first (because we advance the wheel before the first check)

! "label" stores a list of allowed labels. Each column shows the allowed
! labels on each site. The number of rows is k (number of colors---
! e.g., binary, ternary, etc.). If a label (or labels) is not allowed
! on a particular site, then the end of the column will be padded with
! -1.
! For example, consider a 2-lattice and n=2. If k=5 (quintenary) and
! labels 0 and 1 are allowed on site 1 in the parent and labels 2,3,4
! are allowed on the second site in the parent cell, then the table
! "label" will contain:
!    0  0  2  2
!    1  1  3  3
!   -1 -1  4  4
!   -1 -1 -1 -1
forall(j=1:k);label(j,:) = (/((parLabel(j,i),ic=1,n),i=1,nD)/); endforall
! Write a file containing the table of allowed labels/site
open(22,file="debug_label_table.out",access="append")
write(22,'("label #     Label table (k.n*nD)")') 
do ik = 1, k
   write(22,'(i4,8x,30(i2,1x))') ik,label(ik,:)
end do; write(22,*); close(22)


print *,"DEBUG, n,k,nD",n,k,nD
a = -1; flag = .true.
sitePointer = 1

do while (flag) ! Loop over digits (place holders, wheels) in the labeling
   do while (flag) ! Loop over possible values for each digit (labels on the wheel)
      write(*,'("DEBUG: digCnt=",100i2)') digCnt 
!      write(*,'("DEBUG: a=",100i2)') a(label(digCnt,:))
      !print *,"sp",sitepointer
      if (sitePointer < 1) then
         flag = .false.; exit
      endif
      digCnt(sitePointer) = digCnt(sitePointer) + 1   ! Advance the current digit (rotate the wheel one click)
!print *,"digCnt", digCnt
print *,"label at current spot",label(digCnt(sitePointer),sitePointer)
      if (label(digCnt(sitePointer),sitePointer) == -1) then  ! If the wheel is rolling over, reset the label to "zero"   
         digCnt(sitePointer) = 1                  ! (i.e., lowest allowed label, ordinal 1)
         sitePointer = sitePointer - 1            ! and back up one digit (i.e., go left one "wheel")
         cycle
      endif
      write(*,'("DEBUG: sp,dig,E:" 3(i2,1x))') sitepointer,digit(sitepointer),E(sitePointer,digit(sitepointer))
      if(E(sitePointer,digit(sitePointer))==1) exit ! Found a valid label for this site, so exit loop
   enddo
   write(*,'("22DEBUG: digCnt=",100i2)') digCnt 

   a(sitePointer) = label(digCnt(sitePointer),sitePointer)
   write(*,'("Labeling: ",100i1)') a
   if(.not.flag) exit ! Done with the label generation
   if(count(a==digCnt(sitePointer))>iConc(digCnt(sitePointer)+1)) cycle
   sitePointer = sitePointer + 1
   if(sitePointer>n*nD) sitePointer = n*nD
   write(*,'("end of labeling construction",100i1)') a
   stop
   if(is_valid_multiplicity(a,iConc)) then ! We have a valid labeling on the tree, mark it in the
      call generate_index_from_labeling(a,iConc,idxOrig) ! hash table and then mark the symmetry brothers
      if(lab(idxOrig)=='') then ! This labeling hasn't been generated yet (directly or by symmetry permutation)
         lab(idxOrig)='U'
         ! In the hash table, cross out the symmetrical duplicates
         do q = 2, nPerm
!             if(.not. is_valid_multiplicity(a(perm(q,:)),iConc)) cycle
             call generate_index_from_labeling(a(perm(q,:)),iConc,idx) ! permute the labeling then get new index
             if (idx==idxOrig .and. q <= n) lab(idx)='N'! This will happen if the coloring is superperiodic
             ! (i.e., non-primitive superstructure). The q=<n condition makes sure we are considering a
             ! "translation" permutation and not a rotation permutation (they're ordered in the
             ! list...and there are n. The first is the identity so skip that one.)

             ! This is a failsafe and should never trigger if the algorithm is properly implemented
             if (idx > nL) then
                write(*,'("iConc",100(i3,1x))') iConc
                write(*,'(100i1)') a
                write(*,'(100i1)') a(perm(q,:))
                print *,"idx",idx
                print *,"max expected",nL
                print *,"An index outside the expected range occurred in get_permutations_labeling"
                stop
             endif
             if(lab(idx)=='') lab(idx)='D' ! Mark this labeling as a duplicate
          end do
       end if
    end if
 enddo
! If there are no site restrictions, then the hash table is "minimal" and every entry should hove
! been visited. Double check if this is the case. Just another failsafe.
if(all(E==1) .and. any(lab=='')) then 
   print*,"There are no site restrictions and yet not every labeling was marked in generate_permutation_labelings"
   stop "There is a bug in generate_permutations_labeling in labeling_related.f90"
endif

CONTAINS
FUNCTION is_valid_multiplicity(labeling,concList)
logical is_valid_multiplicity
integer, intent(in) :: labeling(:)
integer, intent(in) :: concList(:)
integer i

is_valid_multiplicity = .true.
if (sum(concList)/=n*nD) stop "Something is strange in is_valid_multiplicity"
do i = 0, size(concList,1)-1 
   if(count(labeling==i)/=concList(i+1)) is_valid_multiplicity = .false.
enddo

END FUNCTION is_valid_multiplicity
END SUBROUTINE generate_disjoint_permutation_labelings


END MODULE labeling_related
