! ***********************************************************************
!
!   Copyright (C) 2013-2019  Bill Paxton & The MESA Team
!
!   MESA is free software; you can use it and/or modify
!   it under the combined terms and restrictions of the MESA MANIFESTO
!   and the GNU General Library Public License as published
!   by the Free Software Foundation; either version 2 of the License,
!   or (at your option) any later version.
!
!   You should have received a copy of the MESA MANIFESTO along with
!   this software; if not, it is available at the mesa website:
!   http://mesa.sourceforge.net/
!
!   MESA is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!   See the GNU Library General Public License for more details.
!
!   You should have received a copy of the GNU Library General Public License
!   along with this software; if not, write to the Free Software
!   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
!
! ***********************************************************************


      module star_solver_15066

      use star_private_def
      use const_def, only: dp
      use num_def
      use mtx_def
      use mtx_lib, only: band_multiply_xa, block_multiply_xa

      use hydro_solver_procs


      implicit none

      private
      public :: solver_15066, get_solver_work_sizes_15066


      contains


      subroutine solver_15066( &
            s, nz, nvar, dx, &
            gold_tolerances_level, tol_correction_norm, &
            xscale, equ, work, lwork, iwork, liwork, AF, &
            lrpar, rpar, lipar, ipar, convergence_failure, ierr)
         use alloc, only: non_crit_get_quad_array, non_crit_return_quad_array
         use utils_lib, only: realloc_if_needed_1, quad_realloc_if_needed_1, fill_with_NaNs

         type (star_info), pointer :: s
         ! the primary variables
         integer, intent(in) :: nz ! number of zones
         integer, intent(in) :: nvar ! number of variables per zone
         real(dp), pointer, dimension(:) :: dx ! =(nvar,nz)

         real(dp), pointer, dimension(:) :: xscale ! =(nvar,nz)
         real(dp), pointer, dimension(:) :: equ ! =(nvar,nz)
         ! equ(i) has the residual for equation i, i.e., the difference between
         ! the left and right hand sides of the equation.

         ! work arrays. required sizes provided by the routine solver_work_sizes.
         ! for standard use, set work and iwork to 0 before calling.
         ! NOTE: these arrays contain some optional parameter settings and outputs.
         ! see num_def for details.
         integer, intent(in) :: lwork, liwork
         real(dp), intent(inout), target :: work(:) ! (lwork)
         integer, intent(inout), target :: iwork(:) ! (liwork)
         real(dp), pointer, dimension(:) :: AF ! for factored jacobian
            ! will be allocated or reallocated as necessary.

         ! convergence criteria
         integer, intent(in) :: gold_tolerances_level ! 0, 1, or 2
         real(dp), intent(in) :: tol_correction_norm
            ! a trial solution is considered to have converged if
            ! max_correction <= tol_max_correction and
            !
            ! either
            !          (correction_norm <= tol_correction_norm)
            !    .and. (residual_norm <= tol_residual_norm)
            ! or
            !          (correction_norm*residual_norm <= tol_corr_resid_product)
            !    .and. (abs(slope) <= tol_abs_slope_min)
            !
            ! where "slope" is slope of the line for line search in the solver,
            ! and is analogous to the slope of df/ddx in a 1D solver root finder.

         ! parameters for caller-supplied routines
         integer, intent(in) :: lrpar, lipar
         real(dp), intent(inout) :: rpar(:) ! (lrpar)
         integer, intent(inout) :: ipar(:) ! (lipar)

         ! output
         logical, intent(out) :: convergence_failure
         integer, intent(out) :: ierr ! 0 means okay.

         integer :: ldAF, neqns, mljac, mujac
         real(dp), pointer :: AF_copy(:) ! =(ldAF, neq)

         integer(8) :: test_time0, test_time1, clock_rate
         logical :: do_test_timing

         include 'formats.dek'

         s% nvar_solver_solver = nvar

         do_test_timing = (work(r_test_time) /= 0)

         if (do_test_timing) then
            call system_clock(test_time0,clock_rate)
         else
            test_time0 = 0
         endif

         work(r_test_time) = 0

         ierr = 0

         neqns = nvar*nz
         ldAF = 3*nvar

         call realloc_if_needed_1(AF,ldAF*neqns,(ldAF+2)*200,ierr)
         if (ierr /= 0) return
         AF_copy => AF

         if (s% fill_arrays_with_NaNs) call fill_with_NaNs(AF_copy)

         call do_solver( &
            s, nz, nvar, dx, AF_copy, ldAF, &
            neqns, gold_tolerances_level, tol_correction_norm, xscale, equ, &
            work, lwork, iwork, liwork, &
            lrpar, rpar, lipar, ipar, convergence_failure, ierr)
         s% solver_iter = 0

         if (do_test_timing) then
            call system_clock(test_time1,clock_rate)
            work(r_test_time) = work(r_test_time) + dble(test_time1 - test_time0) / clock_rate
         end if


         contains


         logical function bad_isize(a,sz,str)
            integer :: a(:)
            integer, intent(in) :: sz
            character (len=*), intent(in) :: str
            bad_isize = (size(a,dim=1) < sz)
            if (.not. bad_isize) return
            ierr = -1
            write(*,*) 'interpolation: bad sizes for ' // trim(str)
            return
         end function bad_isize


         logical function bad_size(a,sz,str)
            real(dp) :: a(:)
            integer, intent(in) :: sz
            character (len=*), intent(in) :: str
            bad_size = (size(a,dim=1) < sz)
            if (.not. bad_size) return
            ierr = -1
            write(*,*) 'interpolation: bad sizes for ' // trim(str)
            return
         end function bad_size


         logical function bad_size_dble(a,sz,str)
            real(dp) :: a(:)
            integer, intent(in) :: sz
            character (len=*), intent(in) :: str
            bad_size_dble = (size(a,dim=1) < sz)
            if (.not. bad_size_dble) return
            ierr = -1
            write(*,*) 'interpolation: bad sizes for ' // trim(str)
            return
         end function bad_size_dble


         logical function bad_sizes(a,sz1,sz2,str)
            real(dp) :: a(:,:)
            integer, intent(in) :: sz1,sz2
            character (len=*), intent(in) :: str
            bad_sizes = (size(a,dim=1) < sz1 .or. size(a,dim=2) < sz2)
            if (.not. bad_sizes) return
            ierr = -1
            write(*,*) 'interpolation: bad sizes for ' // trim(str)
            return
         end function bad_sizes


      end subroutine solver_15066


      subroutine do_solver( &
            s, nz, nvar, dx1, AF1, ldAF, neq, &
            gold_tolerances_level, tol_correction_norm, xscale1, equ1, &
            work, lwork, iwork, liwork, &
            lrpar, rpar, lipar, ipar, convergence_failure, ierr)

         type (star_info), pointer :: s

         integer, intent(in) :: nz, nvar, ldAF, neq

         real(dp), pointer, dimension(:) :: AF1 ! =(ldAF, neq)
         real(dp), pointer, dimension(:) :: dx1, equ1, xscale1

         ! controls
         integer, intent(in) :: gold_tolerances_level
         real(dp), intent(in) :: tol_correction_norm

         ! parameters for caller-supplied routines
         integer, intent(in) :: lrpar, lipar
         real(dp), intent(inout) :: rpar(:) ! (lrpar)
         integer, intent(inout) :: ipar(:) ! (lipar)

         ! work arrays
         integer, intent(in) :: lwork, liwork
         real(dp), intent(inout), target :: work(:) ! (lwork)
         integer, intent(inout), target :: iwork(:) ! (liwork)

         ! output
         logical, intent(out) :: convergence_failure
         integer, intent(out) :: ierr

         ! info saved in work arrays

         real(dp), dimension(:,:), pointer :: dxsave, ddxsave, B, grad_f, soln
         real(dp), dimension(:), pointer :: dxsave1, ddxsave1, B1, grad_f1, &
            row_scale_factors1, col_scale_factors1, soln1, save_ublk1, save_dblk1, save_lblk1
         real(dp), dimension(:,:), pointer ::  rhs
         integer, dimension(:), pointer :: ipiv1
         real(dp), dimension(:,:), pointer :: &
            ddx, xgg, ddxd, ddxdd, xder, equsave

         integer, dimension(:), pointer :: ipiv_blk1
         character (len=nz) :: equed1

         real(dp), dimension(:,:), pointer :: A, Acopy
         real(dp), dimension(:), pointer :: A1, Acopy1
         real(dp), dimension(:), pointer :: lblk1, dblk1, ublk1
         real(dp), dimension(:), pointer :: lblkF1, dblkF1, ublkF1

         ! locals
         real(dp)  ::  &
            coeff, f, slope, residual_norm, max_residual, max_residual_cv, max_residual_other, &
            corr_norm_min, resid_norm_min, correction_factor, temp_correction_factor, &
            correction_norm, corr_norm_initial, max_correction, max_correction_cv, slope_extra, &
            tol_residual_norm, tol_max_residual, &
            tol_residual_norm2, tol_max_residual2, &
            tol_residual_norm3, tol_max_residual3, &
            tol_max_correction, tol_abs_slope_min, tol_corr_resid_product, &
            min_corr_coeff, max_corr_min, max_resid_min, max_abs_correction, max_abs_correction_cv
         integer :: iter, max_tries, ndiag, zone, idiag, tiny_corr_cnt, ldA, i, j, k, info, &
            last_jac_iter, max_iterations_for_jacobian, force_iter_value, mljac, mujac, &
            reuse_count, &
            iter_for_resid_tol2, iter_for_resid_tol3, &
            caller_id, max_corr_k, max_corr_j, max_resid_k, max_resid_j, max_corr_cv_k, max_resid_cv_k
         integer(8) :: test_time0, test_time1, time0, time1, clock_rate
         character (len=strlen) :: err_msg
         logical :: first_try, dbg_msg, passed_tol_tests, &
            do_mtx_timing, do_test_timing, doing_extra, okay
         integer, parameter :: num_tol_msgs = 15
         character (len=32) :: tol_msg(num_tol_msgs)
         character (len=64) :: message
         real(dp), pointer, dimension(:) :: p1_1, p1_2
         !character (len=1) :: equed

         real(dp), pointer, dimension(:,:) :: dx, equ, xscale ! (nvar,nz)
         real(dp), pointer, dimension(:,:) :: AF ! (ldAF,neq)
         real(dp), pointer, dimension(:,:,:) :: ublk, dblk, lblk ! (nvar,nvar,nz)
         real(dp), dimension(:,:,:), pointer :: lblkF, dblkF, ublkF ! (nvar,nvar,nz)

         include 'formats.dek'

         dx(1:nvar,1:nz) => dx1(1:neq)
         equ(1:nvar,1:nz) => equ1(1:neq)
         xscale(1:nvar,1:nz) => xscale1(1:neq)
         AF(1:ldAF,1:neq) => AF1(1:ldAF*neq)

         do_mtx_timing = (work(r_mtx_time) /= 0)
         work(r_mtx_time) = 0

         tol_msg(1) = 'avg corr'
         tol_msg(2) = 'max corr '
         tol_msg(3) = 'avg+max corr'
         tol_msg(4) = 'avg resid'
         tol_msg(5) = 'avg corr+resid'
         tol_msg(6) = 'max corr, avg resid'
         tol_msg(7) = 'avg+max corr, avg resid'
         tol_msg(8) = 'max resid'
         tol_msg(9) = 'avg corr, max resid'
         tol_msg(10) = 'max corr+resid'
         tol_msg(11) = 'avg+max corr, max resid'
         tol_msg(12) = 'avg+max resid'
         tol_msg(13) = 'avg corr, avg+max resid'
         tol_msg(14) = 'max corr, avg+max resid'
         tol_msg(15) = 'avg+max corr+resid'

         ierr = 0
         iter = 0
         s% solver_iter = iter

         call set_param_defaults
         dbg_msg = (iwork(i_debug) /= 0)
         
         tol_residual_norm = work(r_tol_residual_norm)
         tol_max_residual = work(r_tol_max_residual)
         tol_residual_norm2 = work(r_tol_residual_norm2)
         tol_max_residual2 = work(r_tol_max_residual2)
         tol_residual_norm3 = work(r_tol_residual_norm3)
         tol_max_residual3 = work(r_tol_max_residual3)

         tol_max_correction = work(r_tol_max_correction)
         tol_abs_slope_min = work(r_tol_abs_slope_min)
         tol_corr_resid_product = work(r_tol_corr_resid_product)
         min_corr_coeff = work(r_min_corr_coeff)
         
         if (gold_tolerances_level == 2) then
            iter_for_resid_tol2 = s% gold2_iter_for_resid_tol2
            iter_for_resid_tol3 = s% gold2_iter_for_resid_tol3
         else if (gold_tolerances_level == 1) then
            iter_for_resid_tol2 = s% gold_iter_for_resid_tol2
            iter_for_resid_tol3 = s% gold_iter_for_resid_tol3
         else
            iter_for_resid_tol2 = s% iter_for_resid_tol2
            iter_for_resid_tol3 = s% iter_for_resid_tol3
         end if

         caller_id = iwork(i_caller_id)

         mljac = 2*nvar-1
         mujac = mljac
         idiag = mljac+mujac+1
         ndiag = 3*nvar
         ldA = ndiag
         call pointers(ierr)
         if (ierr /= 0) return

         doing_extra = .false.
         passed_tol_tests = .false. ! goes true when pass the tests
         convergence_failure = .false. ! goes true when time to give up
         coeff = 1.d0
         xscale = 1.d0

         residual_norm=0
         max_residual=0
         max_residual_cv=0 ! when using convective velocity variables, max residuals and corrections are saved separately
         max_residual_other=0
         corr_norm_min=1d99
         max_corr_min=1d99
         max_resid_min=1d99
         resid_norm_min=1d99
         correction_factor=0
         f=0d0
         slope=0d0

         call set_xscale_info(s, nvar, nz, xscale, ierr)
         if (ierr /= 0) then
            if (dbg_msg) &
               write(*, *) 'solver failure: set_xscale_info returned ierr', ierr
            convergence_failure = .true.
            return
         end if
         
         if (s% trace_evolve) write(*,*) 'solver startup call eval_equations'
         call eval_equations( &
            iter, nvar, nz, dx, xscale, equ, lrpar, rpar, lipar, ipar, ierr)         
         if (ierr /= 0) then
            if (dbg_msg) &
               write(*, *) 'solver failure: eval_equations returned ierr', ierr
            convergence_failure = .true.
            return
         end if
         if (s% trace_evolve) write(*,*) 'solver done eval_equations'
         
         call sizequ_15066( &
            iter, nvar, nz, equ, &
            residual_norm, max_residual, max_resid_k, max_resid_j, &
            max_residual_cv, max_resid_cv_k, &
            lrpar, rpar, lipar, ipar, ierr)
         if (ierr /= 0) then
            if (dbg_msg) &
               write(*, *) 'solver failure: sizequ_15066 returned ierr', ierr
            convergence_failure = .true.
            return
         end if

         first_try = .true.
         iter = 1
         s% solver_iter = iter
         max_tries = abs(iwork(i_max_tries))
         last_jac_iter = 0
         tiny_corr_cnt = 0

         if (iwork(i_max_iterations_for_jacobian) == 0) then
            max_iterations_for_jacobian = 1000000
         else
            max_iterations_for_jacobian = iwork(i_max_iterations_for_jacobian)
         end if

      iter_loop: do while (.not. passed_tol_tests)

            if (dbg_msg .and. first_try) write(*, *)
            
            max_resid_j = -1
            max_corr_j = -1

            if (iter >= iter_for_resid_tol2) then
               if (iter < iter_for_resid_tol3) then
                  tol_residual_norm = tol_residual_norm2
                  tol_max_residual = tol_max_residual2
                  if (dbg_msg .and. iter == iter_for_resid_tol2) &
                     write(*,1) 'tol2 residual tolerances: norm, max', &
                        tol_residual_norm, tol_max_residual
               else
                  tol_residual_norm = tol_residual_norm3
                  tol_max_residual = tol_max_residual3
                  if (dbg_msg .and. iter == iter_for_resid_tol3) &
                     write(*,1) 'tol3 residual tolerances: norm, max', &
                        tol_residual_norm, tol_max_residual
               end if
            else if (dbg_msg .and. iter == 1) then
               write(*,2) 'solver_call_number', s% solver_call_number
               write(*,2) 'gold tolerances level', gold_tolerances_level
               write(*,1) 'correction tolerances: norm, max', &
                  tol_correction_norm, tol_max_correction
               write(*,1) 'tol1 residual tolerances: norm, max', &
                  tol_residual_norm, tol_max_residual
            end if

            call setmatrix( &
               neq, dx, xscale, dxsave, ddxsave, lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then
               call write_msg('setmatrix returned ierr /= 0')
               convergence_failure = .true.
               exit iter_loop
            end if
            iwork(i_num_jacobians) = iwork(i_num_jacobians) + 1
            last_jac_iter = iter
            
         reuse_mtx_loop: do reuse_count = 0, s% num_times_solver_reuse_mtx
         
            if (.not. solve_equ(reuse_count)) then ! either singular or horribly ill-conditioned
               write(err_msg, '(a, i5, 3x, a)') 'info', ierr, 'bad_matrix'
               call oops(err_msg)
               exit iter_loop
            end if

            ! inform caller about the correction
            call inspectB(iter, nvar, nz, dx, soln, xscale, lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then
               call oops('inspectB returned ierr')
               exit iter_loop
            end if

            ! compute size of scaled correction B
            call sizeB_15066(iter, nvar, nz, soln, xscale, &
                     max_correction, correction_norm, max_corr_k, max_corr_j, &
                     max_correction_cv, max_corr_cv_k, &
                     lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then
               call oops('correction rejected by sizeB_15066')
               exit iter_loop
            end if

            correction_norm = abs(correction_norm)
            max_abs_correction = abs(max_correction)
            max_abs_correction_cv = abs(max_correction_cv)
            corr_norm_min = min(correction_norm, corr_norm_min)
            max_corr_min = min(max_abs_correction, max_corr_min)

            if (is_bad_num(correction_norm) .or. is_bad_num(max_abs_correction)) then
               ! bad news -- bogus correction
               call oops('bad result from sizeB_15066 -- correction info either NaN or Inf')
               if (s% stop_for_bad_nums) then
                  write(*,1) 'correction_norm', correction_norm
                  write(*,1) 'max_correction', max_correction
                  stop 'solver'
               end if
               exit iter_loop
            end if

            if (.not. s% ignore_too_large_correction) then
               if ((correction_norm > work(r_corr_param_factor)*work(r_scale_correction_norm)) .and. &
                     (iwork(i_try_really_hard) == 0)) then
                  call oops('avg corr too large')
                  exit iter_loop
               endif
            end if

            ! shrink the correction if it is too large
            correction_factor = 1d0
            temp_correction_factor = 1d0

            if (correction_norm*correction_factor > work(r_scale_correction_norm)) then
               correction_factor = min(correction_factor,work(r_scale_correction_norm)/correction_norm)
            end if
            
            if (max_abs_correction*correction_factor > work(r_scale_max_correction)) then
               temp_correction_factor = work(r_scale_max_correction)/max_abs_correction
            end if

            if (s% conv_vel_flag) then
               if (max_abs_correction_cv*correction_factor > s% conv_vel_scale_max_correction) then
                  temp_correction_factor = s% conv_vel_scale_max_correction/max_abs_correction_cv
               end if
            end if

            if ((.not. s% conv_vel_flag .and. iter > s% solver_itermin_until_reduce_min_corr_coeff) .or. &
                  (s% conv_vel_flag .and. iter > s% conv_vel_solver_itermin_until_reduce_min_corr_coeff)) then
               if (min_corr_coeff == 1d0 .and. &
                  s% solver_reduced_min_corr_coeff < 1d0) then
                     min_corr_coeff = s% solver_reduced_min_corr_coeff
               end if
            end if

            correction_factor = max(min_corr_coeff, correction_factor)
            if (.not. s% ignore_min_corr_coeff_for_scale_max_correction) then
               temp_correction_factor = max(min_corr_coeff, temp_correction_factor)
            end if
            correction_factor = min(correction_factor, temp_correction_factor)

            ! fix B if out of definition domain
            call Bdomain( &
               iter, nvar, nz, soln, dx, xscale, correction_factor, &
               lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then ! correction cannot be fixed
               call oops('correction rejected by Bdomain')
               exit iter_loop
            end if

            if (min_corr_coeff < 1d0) then
               ! compute gradient of f = equ<dot>jacobian
               ! NOTE: NOT jacobian<dot>equ
               call block_multiply_xa(nvar, nz, lblk1, dblk1, ublk1, equ1, grad_f1)

               slope = eval_slope(nvar, nz, grad_f, soln)
               if (is_bad_num(slope) .or. slope > 0d0) then ! a very bad sign
                  if (is_bad_num(slope) .and. s% stop_for_bad_nums) then
                     write(*,1) 'slope', slope
                     stop 'solver'
                  end if
                  slope = 0d0
                  min_corr_coeff = 1d0
               end if

            else

               slope = 0d0

            end if
            
            f = 0d0
            call adjust_correction( &
               min_corr_coeff, correction_factor, grad_f1, f, slope, coeff, &
               err_msg, lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then
               call oops(err_msg)
               exit iter_loop
            end if
            s% solver_adjust_iter = 0

            ! coeff is factor by which adjust_correction rescaled the correction vector
            if (coeff > work(r_tiny_corr_factor)*min_corr_coeff .or. min_corr_coeff >= 1d0) then
               tiny_corr_cnt = 0
            else
               tiny_corr_cnt = tiny_corr_cnt + 1
            end if

            ! check the residuals for the equations

            call sizequ_15066( &
               iter, nvar, nz, equ, &
               residual_norm, max_residual, max_resid_k, max_resid_j, &
               max_residual_cv, max_resid_cv_k, &
               lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) then
               call oops('sizequ_15066 returned ierr')
               exit iter_loop
            end if

            if (is_bad_num(residual_norm)) then
               call oops('residual_norm is a a bad number (NaN or Infinity)')
               if (s% stop_for_bad_nums) then
                  write(*,1) 'residual_norm', residual_norm
                  stop 'solver'
               end if
               exit iter_loop
            end if
            
            if (is_bad_num(max_residual)) then
               call oops('max_residual is a a bad number (NaN or Infinity)')
               if (s% stop_for_bad_nums) then
                  write(*,1) 'max_residual', max_residual
                  stop 'solver'
               end if
               exit iter_loop
            end if

            residual_norm = abs(residual_norm)
            max_residual = abs(max_residual)
            max_residual_cv = abs(max_residual_cv)
            s% residual_norm = residual_norm
            s% max_residual = max_residual
            resid_norm_min = min(residual_norm, resid_norm_min)
            max_resid_min = min(max_residual, max_resid_min)
            
            if (max_abs_correction > tol_max_correction*coeff .or. &
                  max_residual > tol_max_residual*coeff) then
               passed_tol_tests = .false.
            else if (s% conv_vel_flag .and. &
               (max_abs_correction_cv > s% conv_vel_tol_max_correction*coeff .or. &
                  (max_residual_cv > s% conv_vel_tol_max_residual*coeff .and. &
                     max_abs_correction_cv > s% conv_vel_min_correction_to_ignore_residual))) then
               passed_tol_tests = .false.
            else
               passed_tol_tests = &
                     (correction_norm <= tol_correction_norm*coeff .and.  &
                      residual_norm <= tol_residual_norm*coeff) &
                   .or.       &
                     (abs(slope) <= tol_abs_slope_min .and.  &
                      correction_norm*residual_norm <= tol_corr_resid_product*coeff*coeff)
            end if

            if (.not. passed_tol_tests) then

               if (iter >= max_tries) then
                  if (max_abs_correction*coeff > tol_max_correction .and. &
                      max_abs_correction*coeff <= s% tol_bad_max_correction .and. &
                        (.not. s% conv_vel_flag .or. &
                           (max_abs_correction_cv*coeff > s% conv_vel_tol_max_correction .and. &
                           max_residual_cv*coeff > s% conv_vel_tol_max_residual))) then
                     passed_tol_tests = &
                           (correction_norm <= tol_correction_norm*coeff .and.  &
                            residual_norm <= tol_residual_norm*coeff) &
                         .or.       &
                           (abs(slope) <= tol_abs_slope_min .and.  &
                            correction_norm*residual_norm <= tol_corr_resid_product*coeff*coeff)
                     if (passed_tol_tests) then
                        s% bad_max_corr_cnt = s% bad_max_corr_cnt + 1
                        exit iter_loop
                     end if
                  end if
                  call get_message
                  message = trim(message) // ' -- give up'
                  if (len_trim(s% retry_message) == 0) &
                     s% retry_message = trim(message) // ' in solver'
                  if (dbg_msg) call write_msg(message)

                     if (.true.) then
                        if (correction_norm > tol_correction_norm*coeff) &
                           write(*,2) 'correction_norm > tol_correction_norm*coeff', &
                              s% model_number, correction_norm, tol_correction_norm*coeff, coeff
                        if (max_abs_correction > tol_max_correction*coeff) &
                           write(*,2) 'max_abs_correction > tol_max_correction*coeff', &
                              s% model_number, max_abs_correction, tol_max_correction*coeff, coeff
                        if (residual_norm > tol_residual_norm*coeff) &
                           write(*,2) 'residual_norm > tol_residual_norm*coeff', &
                              s% model_number, residual_norm, tol_residual_norm*coeff, coeff
                        if (max_residual > tol_max_residual*coeff) &
                           write(*,2) 'max_residual > tol_max_residual*coeff', &
                              s% model_number, max_residual, tol_max_residual*coeff, coeff
                     end if

                  convergence_failure = .true.; exit iter_loop
               else if (.not. first_try .and. .not. s% doing_first_model_of_run) then
                  if (correction_norm > work(r_corr_norm_jump_limit)*corr_norm_min) then
                     call oops('avg correction jumped')
                     exit iter_loop
                  else if (residual_norm > work(r_resid_norm_jump_limit)*resid_norm_min) then
                     call oops('avg residual jumped')
                     exit iter_loop
                  ! we don't check for jumps in the conv_vel equation as it can vary wildly
                  else if (.not. s% conv_vel_flag .and. &
                        max_abs_correction > work(r_max_corr_jump_limit)*max_corr_min) then
                     call oops('max correction jumped')
                     exit iter_loop
                  else if (.not. s% conv_vel_flag .and. &
                        max_residual > work(r_max_resid_jump_limit)*max_resid_min) then
                     call oops('max residual jumped')
                     exit iter_loop
                  else if (.not. s% conv_vel_flag .and. tiny_corr_cnt >= iwork(i_tiny_min_corr_coeff) &
                        .and. min_corr_coeff < 1) then
                     call oops('tiny corrections')
                     exit iter_loop
                  end if
               else if (iwork(i_try_really_hard) == 0) then
                  if (coeff < min(min_corr_coeff,correction_factor)) then
                     call oops('coeff too small')
                     exit iter_loop
                  end if
               end if
            end if

            if (dbg_msg) then
               if (.not. passed_tol_tests) then
                  call get_message
               end if
               ! combine correction and residual from conv vel with the rest
               if (s% conv_vel_flag) then
                  if (max_abs_correction < max_abs_correction_cv) then
                     max_correction = max_correction_cv
                     max_corr_k = max_corr_cv_k
                     max_corr_j = s% i_ln_cvpv0
                  end if
                  if (max_residual < max_residual_cv) then
                     ! restore these lines for debugging cv's
                     !max_residual_other = max_residual
                     !max_residual = max_residual_cv
                     !max_resid_k = max_resid_cv_k
                     !max_resid_j = s% i_ln_cvpv0
                  end if
               end if
               if (.not. passed_tol_tests) then
                  call write_msg(message)
               else if (iter < iwork(i_itermin)) then
                  call write_msg('iter < itermin')
               else
                  call write_msg('okay!')
               end if
            end if

            if (passed_tol_tests .and. max_abs_correction <= tol_max_correction*coeff) &
               s% bad_max_corr_cnt = 0

            if (passed_tol_tests .and. (iter+1 < max_tries)) then
               ! about to declare victory... but may want to do another iteration
               force_iter_value = force_another_iteration( &
                                    iter, iwork(i_itermin), lrpar, rpar, lipar, ipar)
               if (force_iter_value > 0) then
                  passed_tol_tests = .false. ! force another
                  tiny_corr_cnt = 0 ! reset the counter
                  corr_norm_min = 1d99
                  resid_norm_min = 1d99
                  max_corr_min = 1d99
                  max_resid_min = 1d99
               else if (force_iter_value < 0) then ! failure
                  call oops('force iter')
                  exit iter_loop
               end if
            end if

            if (s% use_other_solver_monitor .and. &
                  associated(s% other_solver_monitor)) then
               call s% other_solver_monitor( &
                  s% id, iter, passed_tol_tests, &
                  correction_norm, max_correction, &
                  residual_norm, max_residual, ierr)
               if (ierr /= 0) then
                  call oops('other_solver_monitor')
                  exit iter_loop
               end if
            end if
            
            end do reuse_mtx_loop

            iter=iter+1
            s% solver_iter = iter
            first_try = .false.

         end do iter_loop
            
         if (max_residual > s% warning_limit_for_max_residual .and. .not. convergence_failure) &
            write(*,2) 'WARNING: max_residual > warning_limit_for_max_residual', &
               s% model_number, max_residual, s% warning_limit_for_max_residual


         contains



         subroutine get_message
            include 'formats.dek'
            i = 0
            if (correction_norm > tol_correction_norm*coeff) i = i+1
            if (max_abs_correction > tol_max_correction*coeff .or. &
               (s% conv_vel_flag .and. &
                  max_abs_correction_cv > s% conv_vel_tol_max_correction*coeff)) i = i+2
            if (residual_norm > tol_residual_norm*coeff) i = i+4
            if (max_residual > tol_max_residual*coeff .or. &
               (s% conv_vel_flag .and. &
                  max_residual_cv > s% conv_vel_tol_max_residual*coeff)) i = i+8
            if (i == 0) then
               message = 'out of tries'
            else
               message = tol_msg(i)
            end if
         end subroutine get_message


         subroutine set_param_defaults

            if (iwork(i_itermin) == 0) iwork(i_itermin) = 2
            if (iwork(i_max_tries) == 0) iwork(i_max_tries) = 50
            if (iwork(i_tiny_min_corr_coeff) == 0) iwork(i_tiny_min_corr_coeff) = 25

            if (work(r_tol_residual_norm)==0) work(r_tol_residual_norm)=1d99
            if (work(r_tol_max_residual)==0) work(r_tol_max_residual)=1d99
            if (work(r_tol_max_correction)==0) work(r_tol_max_correction)=1d99
            if (work(r_scale_correction_norm) == 0) work(r_scale_correction_norm) = 2d0
            if (work(r_corr_param_factor) == 0) work(r_corr_param_factor) = 10d0
            if (work(r_scale_max_correction) == 0) work(r_scale_max_correction) = 1d99
            if (work(r_corr_norm_jump_limit) == 0) work(r_corr_norm_jump_limit) = 1d99
            if (work(r_max_corr_jump_limit) == 0) work(r_max_corr_jump_limit) = 1d99
            if (work(r_resid_norm_jump_limit) == 0) work(r_resid_norm_jump_limit) = 1d99
            if (work(r_max_resid_jump_limit) == 0) work(r_max_resid_jump_limit) = 1d99
            if (work(r_min_corr_coeff) == 0) work(r_min_corr_coeff) = 1d-3
            if (work(r_tiny_corr_factor) == 0) work(r_tiny_corr_factor) = 2d0

         end subroutine set_param_defaults


         subroutine oops(msg)
            character (len=*), intent(in) :: msg
            character (len=strlen) :: full_msg
            include 'formats'
            full_msg = trim(msg) // ' -- give up'
            if (len_trim(s% retry_message) == 0) s% retry_message = trim(full_msg) // ' in solver'
            call write_msg(full_msg)
            convergence_failure = .true.
         end subroutine oops


         subroutine adjust_correction( &
               min_corr_coeff_in, max_corr_coeff, grad_f, f, slope, coeff,  &
               err_msg, lrpar, rpar, lipar, ipar, ierr)
            real(dp), intent(in) :: min_corr_coeff_in
            real(dp), intent(in) :: max_corr_coeff
            real(dp), intent(in) :: grad_f(:) ! (neq) ! gradient df/ddx at xold
            real(dp), intent(out) :: f ! 1/2 fvec^2. minimize this.
            real(dp), intent(in) :: slope
            real(dp), intent(out) :: coeff

            ! the new correction is coeff*xscale*soln
            ! with min_corr_coeff <= coeff <= max_corr_coeff
            ! if all goes well, the new x will give an improvement in f

            character (len=*), intent(out) :: err_msg
            integer, intent(in) :: lrpar, lipar
            real(dp), intent(inout) :: rpar(:) ! (lrpar)
            integer, intent(inout) :: ipar(:) ! (lipar)
            integer, intent(out) :: ierr

            integer :: i, j, k, iter, k_max_corr, i_max_corr
            character (len=strlen) :: message
            logical :: first_time
            real(dp) :: a1, alam, alam2, alamin, a2, disc, f2, &
               rhs1, rhs2, temp, test, tmplam, max_corr, fold, min_corr_coeff
            real(dp) :: frac, f_target
            logical :: skip_eval_f, dbg_adjust

            real(dp), parameter :: alf = 1d-2 ! ensures sufficient decrease in f

            real(dp), parameter :: alam_factor = 0.2d0

            include 'formats.dek'

            ierr = 0
            coeff = 0
            dbg_adjust = .false.  !  (s% trace_k > 0 .and. s% trace_k <= nz)

            skip_eval_f = (min_corr_coeff_in == 1)
            if (skip_eval_f) then
               f = 0
            else
               do k=1,nz
                  do i=1,nvar
                     dxsave(i,k) = dx(i,k)
                     ddxsave(i,k) = ddx(i,k)
                  end do
               end do
               f = eval_f(nvar,nz,equ)
               if (is_bad_num(f)) then
                  ierr = -1
                  write(err_msg,*) 'adjust_correction failed in eval_f'
                  if (dbg_msg) write(*,*) &
                     'adjust_correction: eval_f(nvar,nz,equ)', eval_f(nvar,nz,equ)
                  if (s% stop_for_bad_nums) then
                     write(*,1) 'f', f
                     stop 'solver adjust_correction'
                  end if
                  return
               end if
            end if
            fold = f
            min_corr_coeff = min(min_corr_coeff_in, max_corr_coeff) ! make sure min <= max
            alam = max_corr_coeff
            first_time = .true.
            f2 = 0
            alam2 = 0
            if (dbg_adjust) then
               write(*,4) 'max_corr_coeff', k, s% solver_iter, &
                  s% model_number, max_corr_coeff
               write(*,4) 'slope', k, s% solver_iter, &
                  s% model_number, slope
               write(*,4) 'f', k, s% solver_iter, &
                  s% model_number, f
            end if

         search_loop: do iter = 1, 1000

               coeff = max(min_corr_coeff, alam)
               s% solver_adjust_iter = iter

               call apply_coeff(nvar, nz, dx, dxsave, soln, xscale, coeff, skip_eval_f)
               call eval_equations(iter, nvar, nz, dx, xscale, equ, lrpar, rpar, lipar, ipar, ierr)
               if (ierr /= 0) then
                  if (alam > min_corr_coeff .and. s% model_number == 1) then
                     ! try again with smaller correction vector.
                     ! need this to rescue create pre-main-sequence model in some nasty cases.
                     alam = max(alam/10, min_corr_coeff)
                     ierr = 0
                     cycle
                  end if
                  write(err_msg,'(a)') 'adjust_correction failed in eval_equations'
                  if (dbg_msg .or. dbg_adjust) &
                     write(*,2) 'adjust_correction: eval_equations returned ierr', &
                        ierr, min_corr_coeff, max_corr_coeff
                  exit search_loop
               end if

               if (min_corr_coeff == 1) return

               if (dbg_adjust) then
                  do k=1,nz
                     do i=1,nvar
                        write(*,5) trim(s% nameofequ(i)), k, iter, s% solver_iter, &
                           s% model_number, equ(i,k)
                     end do
                  end do
               end if

               f = eval_f(nvar,nz,equ)
               if (is_bad_num(f)) then
                  if (s% stop_for_bad_nums) then
                     write(*,1) 'f', f
                     stop 'solver adjust_correction eval_f'
                  end if
                  if (alam > min_corr_coeff) then
                     alam = max(alam/10, min_corr_coeff)
                     ierr = 0
                     cycle
                  end if
                  err_msg = 'equ norm is NaN or other bad num'
                  ierr = -1
                  exit search_loop
               end if

               f_target = max(fold/2, fold + alf*coeff*slope)
               if (f <= f_target) then
                  return ! sufficient decrease in f
               end if

               if (alam <= min_corr_coeff) then
                  return ! time to give up
               end if

               ! reduce alam and try again
               if (first_time) then
                  tmplam = -slope/(2*(f-fold-slope))
                  first_time = .false.
                  if (dbg_adjust) then
                     write(*,5) 'slope', k, iter, s% solver_iter, &
                        s% model_number, slope
                     write(*,5) 'f', k, iter, s% solver_iter, &
                        s% model_number, f
                     write(*,5) 'fold', k, iter, s% solver_iter, &
                        s% model_number, fold
                     write(*,5) '2*(f-fold-slope)', k, iter, s% solver_iter, &
                        s% model_number, 2*(f-fold-slope)
                  end if
               else ! have two prior f values to work with
                  rhs1 = f - fold - alam*slope
                  rhs2 = f2 - fold - alam2*slope
                  a1 = (rhs1/(alam*alam) - rhs2/(alam2*alam2))/(alam - alam2)
                  a2 = (-alam2*rhs1/(alam*alam) + alam*rhs2/(alam2*alam2))/(alam - alam2)
                  if (dbg_adjust) then
                     write(*,5) 'slope', k, iter, s% solver_iter, &
                        s% model_number, slope
                     write(*,5) 'f', k, iter, s% solver_iter, &
                        s% model_number, f
                     write(*,5) 'f2', k, iter, s% solver_iter, &
                        s% model_number, f2
                     write(*,5) 'fold', k, iter, s% solver_iter, &
                        s% model_number, fold
                     write(*,5) 'alam', k, iter, s% solver_iter, &
                        s% model_number, alam
                     write(*,5) 'alam2', k, iter, s% solver_iter, &
                        s% model_number, alam2
                     write(*,5) 'rhs1', k, iter, s% solver_iter, &
                        s% model_number, rhs1
                     write(*,5) 'rhs2', k, iter, s% solver_iter, &
                        s% model_number, rhs2
                     write(*,5) 'a1', k, iter, s% solver_iter, &
                        s% model_number, a1
                     write(*,5) 'a2', k, iter, s% solver_iter, &
                        s% model_number, a2
                  end if
                  if (a1 == 0) then
                     tmplam = -slope/(2*a2)
                  else
                     disc = a2*a2-3*a1*slope
                     if (disc < 0) then
                        tmplam = alam*alam_factor
                     else if (a2 <= 0) then
                        tmplam = (-a2+sqrt(disc))/(3*a1)
                     else
                        tmplam = -slope/(a2+sqrt(disc))
                     end if
                     if (dbg_adjust) then
                        write(*,5) 'disc', k, iter, s% solver_iter, &
                           s% model_number, disc
                     end if
                  end if
                  if (tmplam > alam*alam_factor) tmplam = alam*alam_factor
               end if

               alam2 = alam
               f2 = f
               alam = max(tmplam, alam*alam_factor, min_corr_coeff)

               if (dbg_adjust) then
                  write(*,5) 'tmplam', k, iter, s% solver_iter, &
                     s% model_number, tmplam
                  write(*,5) 'min_corr_coeff', k, iter, s% solver_iter, &
                     s% model_number, min_corr_coeff
                  write(*,5) 'alam_factor', k, iter, s% solver_iter, &
                     s% model_number, alam_factor
               end if

            end do search_loop

            do k=1,nz
               do i=1,nvar
                  dx(i,k) = dxsave(i,k)
                  ddx(i,k) = ddxsave(i,k)
               end do
            end do

         end subroutine adjust_correction


         subroutine apply_coeff(nvar, nz, dx, dxsave, soln, xscale, coeff, just_use_dx)
            integer, intent(in) :: nvar, nz
            real(dp), intent(inout), dimension(:,:) :: dx
            real(dp), intent(in), dimension(:,:) :: dxsave, soln, xscale
            real(dp), intent(in) :: coeff
            logical, intent(in) :: just_use_dx
            integer :: i, k
            include 'formats'

            if (just_use_dx) then
               if (coeff == 1d0) then
                  do k=1,nz
                     do i=1,nvar
                        dx(i,k) = dx(i,k) + xscale(i,k)*soln(i,k)
                     end do
                  end do
               else
                  do k=1,nz
                     do i=1,nvar
                        dx(i,k) = dx(i,k) + coeff*xscale(i,k)*soln(i,k)
                     end do
                  end do
               end if
               return
            end if
            ! else use dxsave instead of dx
            if (coeff == 1d0) then
               do k=1,nz
                  do i=1,nvar
                     dx(i,k) = dxsave(i,k) + xscale(i,k)*soln(i,k)
                  end do
               end do
               return
            end if
            do k=1,nz
               do i=1,nvar
                  dx(i,k) = dxsave(i,k) + coeff*xscale(i,k)*soln(i,k)
               end do
            end do
         end subroutine apply_coeff


         logical function solve_equ(reuse_count)
            use star_utils, only: start_time, update_time
            use rsp_def, only: NV, MAX_NZN
            integer, intent(in) :: reuse_count
            integer ::  i, k
            real(dp) :: ferr, berr, total_time

            include 'formats.dek'

            solve_equ=.true.
            !$omp simd
            do i=1,neq
               b1(i) = -equ1(i)
            end do

            info = 0

            if (s% doing_timing) then
               call start_time(s, time0, total_time)
            else if (do_mtx_timing) then
               call system_clock(time0, clock_rate)
            end if
            
            if (s% use_DGESVX_in_bcyclic) then
               !$omp simd
               do i = 1, nvar*nvar*nz
                  save_ublk1(i) = ublk1(i)
                  save_dblk1(i) = dblk1(i)
                  save_lblk1(i) = lblk1(i)
               end do
            end if
            
            if (reuse_count == 0) call factor_mtx
            if (info == 0) call solve_mtx
            
            if (s% use_DGESVX_in_bcyclic) then
               !$omp simd
               do i = 1, nvar*nvar*nz
                  ublk1(i) = save_ublk1(i)
                  dblk1(i) = save_dblk1(i)
                  lblk1(i) = save_lblk1(i)
               end do
            end if

            if (s% doing_timing) then
               call update_time(s, time0, total_time, s% time_solver_matrix)
            else if (do_mtx_timing) then
               call system_clock(time1, clock_rate)
               work(r_mtx_time) = work(r_mtx_time) + dble(time1 - time0) / clock_rate
            end if

            if (info /= 0) then
               solve_equ=.false.
               b(1:nvar,1:nz)=0
            end if

         end function solve_equ


         subroutine factor_mtx
            use star_bcyclic, only: bcyclic_factor
            include 'formats.dek'
            call bcyclic_factor( &
               s, nvar, nz, lblk1, dblk1, ublk1, lblkF1, dblkF1, ublkF1, ipiv_blk1, &
               B1, row_scale_factors1, col_scale_factors1, &
               equed1, iter, info)
         end subroutine factor_mtx


         subroutine solve_mtx
            use star_bcyclic, only: bcyclic_solve
            include 'formats.dek'
            call bcyclic_solve( &
               s, nvar, nz, lblk1, dblk1, ublk1, lblkF1, dblkF1, ublkF1, ipiv_blk1, &
               B1, soln1, row_scale_factors1, col_scale_factors1, equed1, &
               iter, info)
         end subroutine solve_mtx


         logical function do_enter_setmatrix( &
                  neq, dx, xscale, lrpar, rpar, lipar, ipar, ierr)
            ! create jacobian by using numerical differences for partial derivatives
            implicit none
            integer, intent(in) :: neq
            real(dp), pointer, dimension(:,:) :: dx, ddx, xscale
            integer, intent(in) :: lrpar, lipar
            real(dp), intent(inout) :: rpar(:) ! (lrpar)
            integer, intent(inout) :: ipar(:) ! (lipar)
            integer, intent(out) :: ierr
            logical :: need_solver_to_eval_jacobian
            integer :: i, j, k
            include 'formats.dek'
            need_solver_to_eval_jacobian = .true.
            call enter_setmatrix(iter,  &
                  nvar, nz, neq, dx, xscale, xder, need_solver_to_eval_jacobian, &
                  size(A,dim=1), A1, lrpar, rpar, lipar, ipar, ierr)
            do_enter_setmatrix = need_solver_to_eval_jacobian
         end function do_enter_setmatrix


         subroutine setmatrix( &
               neq, dx, xscale, dxsave, ddxsave, lrpar, rpar, lipar, ipar, ierr)
            ! create jacobian by using numerical differences for partial derivatives
            use star_utils, only: e00, em1, ep1
            integer, intent(in) :: neq
            real(dp), pointer, dimension(:,:) :: dx, xscale, dxsave, ddxsave
            integer, intent(in) :: lrpar, lipar
            real(dp), intent(inout) :: rpar(:) ! (lrpar)
            integer, intent(inout) :: ipar(:) ! (lipar)
            integer, intent(out) :: ierr

            integer :: j, k, i_var, i_var_sink, i_equ, k_off, cnt_00, cnt_m1, cnt_p1, k_lo, k_hi
            real(dp), dimension(:,:), pointer :: save_equ, save_dx
            real(dp) :: dvar, dequ, dxtra, &
               dx_0, dvardx, dvardx_0, xdum, err
            logical :: need_solver_to_eval_jacobian, testing_partial

            include 'formats.dek'

            ierr = 0
            testing_partial = & ! check inlist parameters
               s% solver_test_partials_dx_0 > 0d0 .and. &
               s% solver_test_partials_k > 0 .and. &
               s% solver_call_number == s% solver_test_partials_call_number .and. &
               s% solver_test_partials_iter_number == iter
            need_solver_to_eval_jacobian = do_enter_setmatrix( &
                  neq, dx, xscale, lrpar, rpar, lipar, ipar, ierr)
            if (ierr /= 0) return

            if (.not. testing_partial) return

            if (testing_partial) then 
               ! get solver_test_partials_var and solver_test_partials_dval_dx
               call eval_partials(s, nvar, xscale, ierr)
               if (ierr /= 0) return
            else
               call eval_equations( &
                  iter, nvar, nz, dx, xscale, equ, lrpar, rpar, lipar, ipar, ierr)
               if (ierr /= 0) then
                  write(*,3) '1st call eval_equations failed'
                  stop 'setmatrix'
               end if
            end if

            allocate(save_dx(nvar,nz), save_equ(nvar,nz))

            do k=1,nz
               do j=1,nvar
                  save_dx(j,k) = dx(j,k)
                  save_equ(j,k) = equ(j,k)
               end do
            end do
            
            s% doing_check_partials = .true. ! let set_vars_for_solver know
            k_lo = s% solver_test_partials_k_low
            if (k_lo > 0 .and. k_lo <= s% nz) then
               k_hi = s% solver_test_partials_k_high
               if (k_hi <= 0) then
                  k_hi = s% nz
               else
                  k_hi = min(k_hi,s% nz)
               end if
               do k = k_lo, k_hi
                  call test_cell_partials(k, dx, xscale, save_dx, save_equ, ierr)
                  if (ierr /= 0) stop 'failed solver_test_partials'
               end do
            else
               k = s% solver_test_partials_k
               call test_cell_partials(k, dx, xscale, save_dx, save_equ, ierr) 
               if (ierr /= 0) stop 'failed solver_test_partials'
            end if
            deallocate(save_dx, save_equ)
            stop 'done solver_test_partials'

         end subroutine setmatrix


         subroutine test_cell_partials(k, dx, xscale, save_dx, save_equ, ierr) 
            use star_utils, only: lookup_nameofvar, lookup_nameofequ
            integer, intent(in) :: k
            real(dp), pointer, dimension(:,:) :: dx, xscale, save_dx, save_equ
            integer, intent(out) :: ierr
            integer :: i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            include 'formats'
            ierr = 0
            write(*,*)
            i_equ = lookup_nameofequ(s, s% solver_test_partials_equ_name)      
            if (i_equ == 0 .and. len_trim(s% solver_test_partials_equ_name) > 0) then
               if (s% solver_test_partials_equ_name == 'lnE') then ! testing eos
                  i_equ = -1
               else if (s% solver_test_partials_equ_name == 'eps_nuc') then ! testing net
                  i_equ = -2
               else if (s% solver_test_partials_equ_name == 'opacity') then ! testing kap
                  i_equ = -3
               else if (s% solver_test_partials_equ_name == 'lnP') then ! testing eos
                  i_equ = -4
               else if (s% solver_test_partials_equ_name == 'non_nuc_neu') then ! testing neu
                  i_equ = -5
               end if 
            else if (i_equ /= 0) then
               write(*,1) 'equ name ' // trim(s% solver_test_partials_equ_name)
            end if
            i_var = lookup_nameofvar(s, s% solver_test_partials_var_name)            
            if (i_var /= 0) write(*,1) 'var name ' // trim(s% solver_test_partials_var_name)
            if (i_var > s% nvar_hydro) then ! get index in xa
               i_var_xa_index = i_var - s% nvar_hydro
            else
               i_var_xa_index = 0
            end if
            i_var_sink = lookup_nameofvar(s, s% solver_test_partials_sink_name)
            i_var_sink_xa_index  = 0
            if (i_var_sink > 0 .and. i_var > s% nvar_hydro) then
               write(*,1) 'sink name ' // trim(s% solver_test_partials_sink_name)
               if (i_var_sink > s% nvar_hydro) then ! get index in xa
                  i_var_sink_xa_index = i_var_sink - s% nvar_hydro
               else
                  write(*,*) 'ERROR: sink name must be a chem name for the current net'
                  ierr = -1
                  return
               end if
            end if
            if (s% solver_test_partials_equ_name == 'all') then
               do i_equ = 1, s% nvar_hydro
                  call test_equ_partials( &
                     i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                     k, dx, xscale, save_dx, save_equ, ierr)   
                  if (ierr /= 0) stop 'failed solver_test_partials'
               end do
            else
               call test_equ_partials( &
                  i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                  k, dx, xscale, save_dx, save_equ, ierr)   
               if (ierr /= 0) stop 'failed solver_test_partials'
            end if     
         end subroutine test_cell_partials               


         subroutine test_equ_partials( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, dx, xscale, save_dx, save_equ, ierr)
            integer, intent(in) :: &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, k
            real(dp), pointer, dimension(:,:) :: dx, xscale, save_dx, save_equ
            integer, intent(out) :: ierr
            real(dp) :: dvardx_0
            integer :: i, j_var_xa_index, j_var_sink_xa_index
            include 'formats'
            if (i_equ /= 0) then
               if (s% solver_test_partials_var_name == 'all') then
                  do i = 1, s% nvar_hydro
                     call test3_partials( &
                        i_equ, i, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                        k, dx, xscale, save_dx, save_equ, ierr)
                     if (ierr /= 0) stop 'failed solver_test_partials'
                     write(*,*)
                  end do
               else if (i_var == 0) then
                  write(*,*) 'failed to recognize variable name'
               else
                  call test3_partials( &
                     i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                     k, dx, xscale, save_dx, save_equ, ierr)
                  if (ierr /= 0) stop 'failed solver_test_partials'               
               end if
            else ! i_equ == 0
               if (i_var /= 0) then
                  call test1_partial( &
                     i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                     k, 0, s% solver_test_partials_dval_dx, dx, xscale, save_dx, save_equ, ierr)
               else ! i_var == 0
                  if (s% solver_test_partials_var <= 0) then
                     write(*,2) 'need to set solver_test_partials_var', s% solver_test_partials_var
                     write(*,2) 'for solver_test_partials_k', s% solver_test_partials_k
                     stop 'failed solver_test_partials'
                  end if
                  if (s% solver_test_partials_var > s% nvar_hydro) then
                     j_var_xa_index = s% solver_test_partials_var - s% nvar_hydro
                     if (s% solver_test_partials_dx_sink > s% nvar_hydro) then
                        j_var_sink_xa_index = s% solver_test_partials_dx_sink - s% nvar_hydro
                     else
                        write(*,*) 'set solver_test_partials_dx_sink to variable index, not to xa index', &
                           s% solver_test_partials_dx_sink
                        stop 'failed solver_test_partials'
                     end if
                  else
                     j_var_xa_index = 0
                     j_var_sink_xa_index = 0
                  end if
                  call test1_partial( &
                     i_equ, s% solver_test_partials_var, s% solver_test_partials_dx_sink, &
                     j_var_xa_index, j_var_sink_xa_index, &                     
                     k, 0, s% solver_test_partials_dval_dx, dx, xscale, save_dx, save_equ, ierr)
               end if
               if (ierr /= 0) stop 'failed solver_test_partials'
            end if               
            write(*,*)
         end subroutine test_equ_partials
         
         
         real(dp) function get_lnE_partial( &
               k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) result(dlnE_d)
            use eos_def, only: i_lnE
            integer, intent(in) :: k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            dlnE_d = 0d0
            if (i_var_xa_index > 0) then 
               dlnE_d = s% d_eos_dxa(i_lnE,i_var_xa_index,k) - &
                        s% d_eos_dxa(i_lnE,i_var_sink_xa_index,k)
            else if (i_var == s% i_lnd) then
               dlnE_d = s% dE_dRho_for_partials(k)*s% rho(k)/s% energy(k)
            else if (i_var == s% i_lnT) then
               dlnE_d = s% Cv_for_partials(k)*s% T(k)/s% energy(k)
            end if
         end function get_lnE_partial
         
         
         real(dp) function get_lnP_partial( &
               k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) result(dlnP_d)
            use eos_def, only: i_lnPgas
            integer, intent(in) :: k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            dlnP_d = 0d0
            if (i_var_xa_index > 0) then 
               dlnP_d = s% Pgas(k)/s% P(k) * &
                  (s% d_eos_dxa(i_lnPgas,i_var_xa_index,k) - s% d_eos_dxa(i_lnPgas,i_var_sink_xa_index,k))
            else if (i_var == s% i_lnd) then
               dlnP_d = s% chiRho_for_partials(k)
            else if (i_var == s% i_lnT) then
               dlnP_d = s% chiT_for_partials(k)
            end if
         end function get_lnP_partial
         
         
         real(dp) function get_eps_nuc_partial( &
               k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) result(deps_nuc_d)
            integer, intent(in) :: k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            deps_nuc_d = 0d0
            if (i_var > s% nvar_hydro) then 
               deps_nuc_d = s% d_epsnuc_dx(i_var_xa_index,k) - s% d_epsnuc_dx(i_var_sink_xa_index,k)
            else if (i_var == s% i_lnd) then
               deps_nuc_d = s% d_epsnuc_dlnd(k)
            else if (i_var == s% i_lnT) then
               deps_nuc_d = s% d_epsnuc_dlnT(k)
            end if
         end function get_eps_nuc_partial
         
         
         real(dp) function get_non_nuc_neu_partial( &
               k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) result(dnon_nuc_neu_d)
            integer, intent(in) :: k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            dnon_nuc_neu_d = 0d0
            if (i_var > s% nvar_hydro) then 
               dnon_nuc_neu_d = 0d0
            else if (i_var == s% i_lnd) then
               dnon_nuc_neu_d = s% d_nonnucneu_dlnd(k)
            else if (i_var == s% i_lnT) then
               dnon_nuc_neu_d = s% d_nonnucneu_dlnT(k)
            end if
         end function get_non_nuc_neu_partial
         
         
         real(dp) function get_opacity_partial( &
               k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) result(dopacity_d)
            integer, intent(in) :: k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index
            dopacity_d = 0d0
            if (i_var > s% nvar_hydro) then 
               dopacity_d = 0d0 ! s% d_opacity_dx(i_var_xa_index,k) - s% d_opacity_dx(i_var_sink_xa_index,k)
            else if (i_var == s% i_lnd) then
               dopacity_d = s% d_opacity_dlnd(k)
            else if (i_var == s% i_lnT) then
               dopacity_d = s% d_opacity_dlnT(k)
            end if
         end function get_opacity_partial


         subroutine test3_partials( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, dx, xscale, save_dx, save_equ, ierr)
            integer, intent(in) :: &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, k
            real(dp), pointer, dimension(:,:) :: dx, xscale, save_dx, save_equ
            integer, intent(out) :: ierr
            real(dp) :: dvardx0_m1, dvardx0_00, dvardx0_p1
            dvardx0_m1 = 0d0
            dvardx0_00 = 0d0
            dvardx0_p1 = 0d0
            if (i_equ > 0) then
               if (i_var > s% nvar_hydro) then ! testing abundance
                  if (k > 1) dvardx0_m1 = s% lblk(i_equ,i_var,k)/xscale(i_var,k-1) - s% lblk(i_equ,i_var_sink,k)/xscale(i_var_sink,k-1)
                  dvardx0_00 = s% dblk(i_equ,i_var,k)/xscale(i_var,k) - s% dblk(i_equ,i_var_sink,k)/xscale(i_var_sink,k)
                  if (k < s% nz) dvardx0_p1 = s% ublk(i_equ,i_var,k)/xscale(i_var,k+1) - s% ublk(i_equ,i_var_sink,k)/xscale(i_var_sink,k+1)
               else
                  if (k > 1) dvardx0_m1 = s% lblk(i_equ,i_var,k)/xscale(i_var,k-1)
                  dvardx0_00 = s% dblk(i_equ,i_var,k)/xscale(i_var,k)
                  if (k < s% nz) dvardx0_p1 = s% ublk(i_equ,i_var,k)/xscale(i_var,k+1)
               end if
            else if (i_equ == -1) then ! 'lnE'
               dvardx0_00 = get_lnE_partial(&
                  k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index)
            elseif (i_equ == -2) then ! 'eps_nuc'
               dvardx0_00 = get_eps_nuc_partial(&
                  k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index)
            else if (i_equ == -3) then ! 'opacity'
               dvardx0_00 = get_opacity_partial(&
                  k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index)
            else if (i_equ == -4) then ! 'lnP'
               dvardx0_00 = get_lnP_partial( &
                  k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) 
            else if (i_equ == -5) then ! 'non_nuc_neu'
               dvardx0_00 = get_non_nuc_neu_partial( &
                  k, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index) 
            end if 
            if (k > 1) then
               call test1_partial( &
                  i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                  k, -1, dvardx0_m1, dx, xscale, save_dx, save_equ, ierr)
               if (ierr /= 0) stop 'test3_partials'
            end if
            call test1_partial( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, 0, dvardx0_00, dx, xscale, save_dx, save_equ, ierr)
            if (ierr /= 0) stop 'test3_partials'
            if (k < s% nz) then
               call test1_partial( &
                  i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                  k, 1, dvardx0_p1, dx, xscale, save_dx, save_equ, ierr)
               if (ierr /= 0) stop 'test3_partials'
            end if
         end subroutine test3_partials
         

         subroutine test1_partial(&
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, dvardx_0, dx, xscale, save_dx, save_equ, ierr)
            use chem_def, only: chem_isos
            integer, intent(in) :: &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, k, k_off
            real(dp), intent(in) :: dvardx_0
            real(dp), pointer, dimension(:,:) :: dx, xscale, save_dx, save_equ
            character (len=3) :: k_off_str
            integer, intent(out) :: ierr 
            character (len = 32) :: equ_str
            real(dp) :: dx_0, err, dvardx, xdum, uncertainty
            include 'formats'
            ierr = 0

            if (i_var > s% nvar_hydro) then ! testing abundance
               dx_0 = s% solver_test_partials_dx_0 * &
                  max(abs(s% xa_start(i_var_xa_index,k) + dx(i_var,k)), &
                      abs(s% xa_start(i_var_xa_index,k)), &
                      1d-99)
               write(*,1) 'var name ' // chem_isos% name(s% chem_id(i_var_xa_index))
               write(*,1) 'sink name ' // chem_isos% name(s% chem_id(i_var_sink_xa_index))
            else
               dx_0 = s% solver_test_partials_dx_0 * &
                  max(abs(s% xh_start(i_var,k) + dx(i_var,k)), &
                      abs(s% xh_start(i_var,k)))
               if (dx_0 == 0d0) dx_0 = s% solver_test_partials_dx_0
            end if
            dvardx = dfridr( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, dx_0, dx, save_dx, err)
            if (dvardx == 0d0 .and. abs(dvardx_0) < 1d-14) then
               xdum = 0d0
            else if (dvardx_0 == 0d0 .and. abs(dvardx) < 1d-14) then
               xdum = 0d0
            else if (dvardx == 0d0 .or. dvardx_0 == 0d0) then
               xdum = 1d0
            else
               xdum = abs(dvardx - dvardx_0)/min(abs(dvardx),abs(dvardx_0))
            end if
            if (ierr /= 0) then
               write(*,*) 'test1_partial failed'
               stop 'setmatrix'
            end if
            if (i_equ /= 0) then
               if (k_off == 0) then
                  k_off_str = ')  '
               else if (k_off == -1) then
                  k_off_str = '-1)'
               else if (k_off == 1) then
                  k_off_str = '+1)'
               end if
               if (dvardx /= 0d0) then
                  uncertainty = abs(err/dvardx)
               else
                  uncertainty = 0d0
               end if
               if (xdum > 1d-5 .and. uncertainty < 1d-6) then
                  write(*, '(a5,1x)', advance='no') '*****'
               else if (uncertainty > 1d-7) then
                  write(*, '(a5,1x)', advance='no') '?????'
               else
                  write(*, '(6x)', advance='no') 
               end if
               if (i_equ > 0) then
                  equ_str = s% nameofequ(i_equ)
               else if (i_equ == -1) then
                  equ_str = 'lnE'
               else if (i_equ == -2) then
                  equ_str = 'eps_nuc'
               else if (i_equ == -3) then
                  equ_str = 'opacity'
               else if (i_equ == -4) then
                  equ_str = 'lnP'
               else if (i_equ == -5) then
                  equ_str = 'non_nuc_neu'
               else
                  equ_str = 'unknown'
               end if
               write(*,'(a70,2x,i5,f10.3,3x,a,f10.3,99(3x,a,1pe26.16))') &
                  'log dfridr rel_diff partials wrt  '  // trim(s% nameofvar(i_var)) // &
                  '(k' // k_off_str // ' of ' // trim(equ_str) // '(k)', &
                  k, safe_log10(xdum), 'log uncertainty', safe_log10(uncertainty), &
                  'analytic', dvardx_0, 'numeric', dvardx, &
                  'analytic/numeric', abs(dvardx_0)/max(1d-99,abs(dvardx))
                  
            else
               write(*,*)
               write(*,1) 'analytic and numeric partials wrt ' // trim(s% nameofvar(i_var)), &
                  dvardx_0, dvardx
               write(*,1) 'log dfridr relative uncertainty for numeric partial', &
                  safe_log10(err/max(1d-99,abs(dvardx)))
               if (dvardx_0 /= 0d0) write(*,1) 'rel_diff', xdum
            end if
         end subroutine test1_partial
            
            
         real(dp) function dfridr_func( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, delta_x, dx, save_dx) result(val)
            integer, intent(in) :: &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, k, k_off
            real(dp), intent(in) :: delta_x
            real(dp), pointer, dimension(:,:) :: dx, save_dx
            include 'formats'
            dx(i_var,k+k_off) = save_dx(i_var,k+k_off) + delta_x
            if (i_var_xa_index > 0) then ! changing abundance
               !write(*,2) 'new dx, x for abundance', i_var, &
               !     dx(i_var,k+k_off), s% xa(i_var - s% nvar_hydro,k+k_off)
               if (i_var_sink_xa_index <= 0 .or. i_var_sink_xa_index > s% species) then
                  write(*,2) 'bad i_var_sink_xa_index', i_var_sink_xa_index
                  stop 'star_solver dfridr_func'
               end if
               dx(i_var_sink,k+k_off) = save_dx(i_var_sink,k+k_off) - delta_x
            end if
            call eval_equations( &
               iter, nvar, nz, dx, xscale, equ, lrpar, rpar, lipar, ipar, ierr)            
            if (ierr /= 0) then
               !exit
               write(*,3) 'call eval_equations failed in dfridr_func'
               stop 'setmatrix'
            end if
            if (i_equ > 0) then
               val = equ(i_equ,k) ! testing partial of residual for cell k equation
            else if (i_equ == 0) then
               val = s% solver_test_partials_val
            else if (i_equ == -1) then ! testing eos
               val = s% lnE(k)
            else if (i_equ == -2) then ! testing net
               val = s% eps_nuc(k)
            else if (i_equ == -3) then ! testing kap
               val = s% opacity(k)
            else if (i_equ == -4) then ! testing eos
               val = s% lnP(k)
            else if (i_equ == -5) then ! testing neu
               val = s% non_nuc_neu(k)
            else
               val = 0d0
            end if
            dx(i_var,k+k_off) = save_dx(i_var,k+k_off)
            if (i_var_sink > 0) & ! restore sink abundance
               dx(i_var_sink,k+k_off) = save_dx(i_var_sink,k+k_off)
         end function dfridr_func


         real(dp) function dfridr( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, hx, dx, save_dx, err)
            integer, intent(in) :: &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, k, k_off
            real(dp), intent(in) :: hx
            real(dp), pointer, dimension(:,:) :: dx, save_dx
            real(dp), intent(out) :: err
            !  this routine returns the first derivative of a function func(x)
            !  at the point x, by ridders method of polynomial extrapolation.
            !  value hx is the initial step size;
            !  it should be an increment for which func changes substantially.
            !  an estimate of the error in the first derivative is returned in err.
            integer, parameter :: ntab = 20
            integer :: i,j
            real(dp) :: x,errt,fac,hh,a(ntab,ntab),xdum,ydum,f1,f2
            real(dp), parameter :: con2=2d0, con=sqrt(con2), big=1d50, safe=2d0
            include 'formats'
            dfridr = 0d0
            hh = hx
            ! 2nd order central difference
            f1 = dfridr_func( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, hh, dx, save_dx)
            !write(*,2) 'f1', 1, f1, save_dx(i_var,k) + hh
            f2 = dfridr_func( &
               i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
               k, k_off, -hh, dx, save_dx)
            !write(*,2) 'f2', 1, f2, save_dx(i_var,k) - hh
            a(1,1) = (f1 - f2)/(2d0*hh)
            !write(*,2) 'dfdx', 1, a(1,1), &
            !   hh, (save_dx(s% solver_test_partials_var,s% solver_test_partials_k) + hh)/ln10, &
            !   save_dx(s% solver_test_partials_var,s% solver_test_partials_k)/ln10
            err = big
            ! succesive columns in the neville tableu will go to smaller stepsizes
            ! and higher orders of extrapolation
            do i=2,ntab
               hh = hh/con
               f1 = dfridr_func( &
                  i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                  k, k_off, hh, dx, save_dx)
               !write(*,2) 'f1', i, f1, save_dx(i_var,k) + hh
               f2 = dfridr_func( &
                  i_equ, i_var, i_var_sink, i_var_xa_index, i_var_sink_xa_index, &
                  k, k_off, -hh, dx, save_dx)
               !write(*,2) 'f2', i, f2, save_dx(i_var,k) - hh
               a(1,i) = (f1 - f2)/(2d0*hh)
               !write(*,2) 'dfdx', i, a(1,i), &
               !   hh, (save_dx(s% solver_test_partials_var,s% solver_test_partials_k) + hh)/ln10, &
               !   save_dx(s% solver_test_partials_var,s% solver_test_partials_k)/ln10
               ! compute extrapolations of various orders; the error stratagy is to compare
               ! each new extrapolation to one order lower but both at the same stepsize
               ! and at the previous stepsize
               fac = con2
               do j=2,i
                  a(j,i) = (a(j-1,i)*fac - a(j-1,i-1))/(fac-1d0)
                  fac = con2*fac
                  errt = max(abs(a(j,i)-a(j-1,i)),abs(a(j,i)-a(j-1,i-1)))
                  if (errt <= err) then
                     err = errt
                     dfridr = a(j,i)
                     !write(*,1) 'dfridr', err/dfridr
                  end if
               end do
               ! if higher order is worse by a significant factor safe, then bail
               if (abs(a(i,i) - a(i-1,i-1)) >= safe*err) then
                  !write(*,1) 'higher order is worse'
                  return
               end if
            end do
         end function dfridr


         subroutine set_xtras(x,num_xtra)
            real(dp) :: x(:,:)
            integer, intent(in) :: num_xtra
            integer :: k
            include 'formats'
            if (.not. s% u_flag) then
               x(1,1:nz) = 0
               x(2,1:nz) = 0
               return
            end if
            do k=1,nz
               x(1,k) = s% u_face(k)
               if (is_bad_num(x(1,k))) then
                  write(*,2) 'exit_setmatrix x(1,k)', k, x(1,k)
                  stop
               end if
            end do
            do k=1,nz
               x(2,k) = s% P_face(k)
               if (is_bad_num(x(2,k))) then
                  write(*,2) 'exit_setmatrix x(2,k)', k, x(2,k)
                  stop
               end if
            end do
         end subroutine set_xtras
            
         
         subroutine store_mix_type_str(str, integer_string, i, k)
            character (len=5) :: str
            character (len=10) :: integer_string
            integer, intent(in) :: i, k
            integer :: mix_type, j
            if (k < 1 .or. k > s% nz) then
               str(i:i) = 'x'
               return
            end if
            mix_type = s% mixing_type(k)
            if (mix_type < 10) then
               j = mix_type+1
               str(i:i) = integer_string(j:j)
            else
               str(i:i) = '?'
            end if
         end subroutine store_mix_type_str


         subroutine write_msg(msg)
            use const_def, only: secyer
            character(*)  :: msg
            
            integer :: k
            character (len=64) :: max_resid_str, max_corr_str
            character (len=5) :: max_resid_mix_type_str, max_corr_mix_type_str
            character (len=10) :: integer_string
            include 'formats'
            
            if (.not. dbg_msg) return
            
            if (max_resid_j < 0) then
               call sizequ_15066( &
                  iter, nvar, nz, equ, &
                  residual_norm, max_residual, max_resid_k, max_resid_j, &
                  max_residual_cv, max_resid_cv_k, &
                  lrpar, rpar, lipar, ipar, ierr)
            end if
            
            if (max_resid_j > 0 .and. max_residual /= max_residual_cv) then
               write(max_resid_str,*) 'max resid ' // trim(s% nameofequ(max_resid_j))
            else if (max_resid_j > 0) then
               write(max_resid_str,*) 'mx rsd_cv ' // trim(s% nameofequ(max_resid_j))
            else
               max_resid_str = ''
            end if
            
            if (max_corr_j < 0) then
               call sizeB_15066(iter, nvar, nz, B, xscale, &
                  max_correction, correction_norm, max_corr_k, max_corr_j, &
                  max_correction_cv, max_corr_cv_k, &
                  lrpar, rpar, lipar, ipar, ierr)
            end if
            
            if (max_corr_j > 0) then
               write(max_corr_str,*) 'max corr ' // trim(s% nameofvar(max_corr_j))
            else
               max_corr_str = ''
            end if
            
            integer_string = '0123456789'
            k = max_corr_k
            call store_mix_type_str(max_corr_mix_type_str, integer_string, 1, k-2)
            call store_mix_type_str(max_corr_mix_type_str, integer_string, 2, k-1)
            call store_mix_type_str(max_corr_mix_type_str, integer_string, 3, k)
            call store_mix_type_str(max_corr_mix_type_str, integer_string, 4, k+1)
            call store_mix_type_str(max_corr_mix_type_str, integer_string, 5, k+2)
            
            k = max_resid_k
            call store_mix_type_str(max_resid_mix_type_str, integer_string, 1, k-2)
            call store_mix_type_str(max_resid_mix_type_str, integer_string, 2, k-1)
            call store_mix_type_str(max_resid_mix_type_str, integer_string, 3, k)
            call store_mix_type_str(max_resid_mix_type_str, integer_string, 4, k+1)
            call store_mix_type_str(max_resid_mix_type_str, integer_string, 5, k+2)

  111       format(i6, 2x, i3, 2x, a, f8.4, &
               2x, a, 1x, e10.3, 2x, a19, 1x, i5, e11.3, 2x, a, &
               2x, a, 1x, e10.3, 2x, a14, 1x, i5, e11.3, 2x, a, &
               2x, a)
            write(*,111) &
               iwork(i_model_number), iter, &
               'coeff', coeff,  &
               '   avg resid', residual_norm,  &
               trim(max_resid_str), max_resid_k, max_residual, &
               'mix type ' // trim(max_resid_mix_type_str),  &
               '   avg corr', correction_norm,  &
               trim(max_corr_str), max_corr_k, max_correction,  &
               'mix type ' // trim(max_corr_mix_type_str),  &
               '   ' // trim(msg)
               
            if (is_bad(slope)) stop 'write_msg'

         end subroutine write_msg


         subroutine pointers(ierr)
            integer, intent(out) :: ierr

            integer :: i, j
            character (len=strlen) :: err_msg

            ierr = 0

            i = num_work_params+1

            A1(1:ndiag*neq) => work(i:i+ndiag*neq-1); i = i+ndiag*neq

            dxsave1(1:neq) => work(i:i+neq-1); i = i+neq
            dxsave(1:nvar,1:nz) => dxsave1(1:neq)

            ddxsave1(1:neq) => work(i:i+neq-1); i = i+neq
            ddxsave(1:nvar,1:nz) => ddxsave1(1:neq)

            B1 => work(i:i+neq-1); i = i+neq
            B(1:nvar,1:nz) => B1(1:neq)

            soln1 => work(i:i+neq-1); i = i+neq
            soln(1:nvar,1:nz) => soln1(1:neq)

            grad_f1(1:neq) => work(i:i+neq-1); i = i+neq
            grad_f(1:nvar,1:nz) => grad_f1(1:neq)

            rhs(1:nvar,1:nz) => work(i:i+neq-1); i = i+neq

            xder(1:nvar,1:nz) => work(i:i+neq-1); i = i+neq

            ddx(1:nvar,1:nz) => work(i:i+neq-1); i = i+neq

            row_scale_factors1(1:neq) => work(i:i+neq-1); i = i+neq

            col_scale_factors1(1:neq) => work(i:i+neq-1); i = i+neq

            save_ublk1(1:nvar*neq) => work(i:i+nvar*neq-1); i = i+nvar*neq
            save_dblk1(1:nvar*neq) => work(i:i+nvar*neq-1); i = i+nvar*neq
            save_lblk1(1:nvar*neq) => work(i:i+nvar*neq-1); i = i+nvar*neq

            if (i-1 > lwork) then
               ierr = -1
               write(*,*) 'use_DGESVX_in_bcyclic', s% use_DGESVX_in_bcyclic
               write(*,  &
                  '(a, i12, a, i12, e26.6)') 'solver: lwork is too small.  must be at least', i-1, &
                  '   but is only ', lwork, dble(i-1 - lwork)/(neq*nvar)
               return
            end if

            i = num_iwork_params+1
            ipiv1(1:neq) => iwork(i:i+neq-1); i = i+neq
            if (i-1 > liwork) then
               ierr = -1
               write(*, '(a, i6, a, i6)')  &
                        'solver: liwork is too small.  must be at least', i,  &
                        '   but is only ', liwork
               return
            end if

            ipiv_blk1(1:neq) => ipiv1(1:neq)

            A(1:ndiag,1:neq) => A1(1:ndiag*neq)
            Acopy1 => A1
            Acopy => A

            ublk1(1:nvar*neq) => A1(1:nvar*neq)
            dblk1(1:nvar*neq) => A1(1+nvar*neq:2*nvar*neq)
            lblk1(1:nvar*neq) => A1(1+2*nvar*neq:3*nvar*neq)

            lblk(1:nvar,1:nvar,1:nz) => lblk1(1:nvar*neq)
            dblk(1:nvar,1:nvar,1:nz) => dblk1(1:nvar*neq)
            ublk(1:nvar,1:nvar,1:nz) => ublk1(1:nvar*neq)

            ublkF1(1:nvar*neq) => AF1(1:nvar*neq)
            dblkF1(1:nvar*neq) => AF1(1+nvar*neq:2*nvar*neq)
            lblkF1(1:nvar*neq) => AF1(1+2*nvar*neq:3*nvar*neq)

            lblkF(1:nvar,1:nvar,1:nz) => lblkF1(1:nvar*neq)
            dblkF(1:nvar,1:nvar,1:nz) => dblkF1(1:nvar*neq)
            ublkF(1:nvar,1:nvar,1:nz) => ublkF1(1:nvar*neq)

         end subroutine pointers


         real(dp) function eval_slope(nvar, nz, grad_f, B)
            integer, intent(in) :: nvar, nz
            real(dp), intent(in), dimension(:,:) :: grad_f, B
            integer :: k, i
            eval_slope = 0
            do i=1,nvar
               eval_slope = eval_slope + dot_product(grad_f(i,1:nz),B(i,1:nz))
            end do
         end function eval_slope


         real(dp) function eval_f(nvar, nz, equ)
            integer, intent(in) :: nvar, nz
            real(dp), intent(in), dimension(:,:) :: equ
            integer :: k, i
            real(dp) :: q
            include 'formats.dek'
            eval_f = 0
            do k = 1, nz
               do i = 1, nvar
                  q = equ(i,k)
                  eval_f = eval_f + q*q
               end do
            end do
            eval_f = eval_f/2
         end function eval_f


      end subroutine do_solver


      subroutine get_solver_work_sizes_15066(s, nvar, nz, lwork, liwork, ierr)
         type (star_info), pointer :: s
         integer, intent(in) :: nvar, nz
         integer, intent(out) :: lwork, liwork, ierr

         integer :: ndiag, neq

         include 'formats.dek'

         ierr = 0
         neq = nvar*nz
         ndiag = 3*nvar
         liwork = num_iwork_params + neq
         lwork = num_work_params + neq*(ndiag + 10 + 3*nvar)

      end subroutine get_solver_work_sizes_15066


      subroutine sizeB_15066( &
            iter, nvar, nz, B, xscale, &
            max_correction, correction_norm, max_zone, max_var, &
            max_correction_cv, max_zone_cv, &
            lrpar, rpar, lipar, ipar, ierr)
         integer, intent(in) :: iter, nvar, nz
         real(dp), pointer, dimension(:,:) :: B, xscale ! (nvar, nz)
         real(dp), intent(out) :: correction_norm ! a measure of the average correction
         real(dp), intent(out) :: max_correction, max_correction_cv ! magnitude of the max correction
         integer, intent(in) :: lrpar, lipar
         real(dp), intent(inout) :: rpar(:) ! (lrpar)
         integer, intent(inout) :: ipar(:) ! (lipar)
         integer, intent(out) :: max_zone, max_var, max_zone_cv, ierr

         integer :: k, i, num_terms, j, n, nvar_hydro, &
            skip1, skip2, skip3, jmax, num_xa_terms, i_alpha_RTI, i_ln_cvpv0
         real(dp) :: abs_corr, sum_corr, sum_xa_corr, x_limit, &
            max_abs_correction, max_abs_correction_cv, max_abs_corr_for_k, max_abs_xa_corr_for_k
         type (star_info), pointer :: s
         logical :: found_NaN, found_bad_num, report
         logical, parameter :: dbg = .false.
         logical, parameter :: check_for_bad_nums = .true.
         logical, parameter :: save_max_abs_corr_for_k = .true.

         include 'formats'

         if (dbg) write(*, *) 'enter sizeB_15066'

         ierr = 0
         call get_star_ptr(ipar(ipar_id), s, ierr)
         if (ierr /= 0) then
            write(*,*) 'bad id for sizeB_15066'
            return
         end if

         n = nz
         nvar_hydro = min(nvar, s% nvar_hydro)

         if (s% include_L_in_error_est) then
            skip1 = 0
         else
            skip1 = s% i_lum
         end if

         if (s% include_v_in_error_est) then
            skip2 = 0
         else
            skip2 = s% i_v
         end if

         if (s% include_u_in_error_est) then
            skip3 = 0
         else
            skip3 = s% i_u
         end if
         
         i_alpha_RTI = s% i_alpha_RTI
         i_ln_cvpv0 = s% i_ln_cvpv0

         max_zone = 0
         max_var = 0
         num_terms = 0
         num_xa_terms = 0
         sum_corr = 0
         sum_xa_corr = 0
         max_correction = 0
         max_correction_cv = 0
         max_abs_correction = 0
         max_abs_correction_cv = 0
         x_limit = s% correction_xa_limit
         found_NaN = .false.
         found_bad_num = .false.
         report = s% report_ierr
         cell_loop: do k = 1, nz
            max_abs_corr_for_k = 0
            max_abs_xa_corr_for_k = 0

            if (s% do_struct_hydro .or. s% do_struct_thermo) then
               if (s% do_burn .or. s% do_mix) then
                  jmax = nvar
               else
                  jmax = nvar_hydro
               end if
               var_loop: do j = 1, jmax
                  if (j == skip1 .or. &
                      j == skip2 .or. &
                      j == skip3 .or. &
                      j == i_alpha_RTI) cycle
                  if (check_for_bad_nums) then
                     if (is_bad_num(B(j,k))) then
                        found_bad_num = .true.
                        if (report) write(*,2) 'sizeB_15066: bad num for correction ' // &
                           s% nameofvar(j), k, B(j,k)
                        if (s% stop_for_bad_nums) then
                           found_NaN = .true.
                           write(*,3) s% nameofvar(j) // ' B(j,k)', j, k, B(j,k)
                           stop 'sizeB_15066'
                        end if
                        
                        max_zone = k
                        max_var = j
                        exit cell_loop
                        
                        cycle
                     end if
                  end if
                  if (j > nvar_hydro) then
                     if (s% xa_start(j-nvar_hydro,k) < x_limit) cycle
                  end if

                  abs_corr = abs(B(j,k))
                  if (is_bad_num(abs_corr)) then
                     found_bad_num = .true.
                     if (report) write(*,3) 'B(j,k)', j, k, B(j,k)
                     if (s% stop_for_bad_nums) found_NaN = .true.
                  end if
                  if (abs_corr > max_abs_corr_for_k &
                     .and. .not. (j > nvar_hydro .and. s% ignore_species_in_max_correction)) &
                        max_abs_corr_for_k = abs_corr
                  if (j /= i_ln_cvpv0 .or. .not. s% convergence_separate_equ_conv_vel_corrections) then
                     if (abs_corr > max_abs_correction &
                        .and. .not. (j > nvar_hydro .and. s% ignore_species_in_max_correction)) then
                        max_correction = B(j,k)
                        max_abs_correction = abs_corr
                        max_zone = k
                        max_var = j
                     end if
                  else
                     if (abs_corr > max_abs_correction_cv) then
                        max_correction_cv = B(j,k)
                        max_abs_correction_cv = abs_corr
                        max_zone_cv = k
                     end if
                  end if
                  if (j > nvar_hydro) then
                     num_xa_terms = num_xa_terms + 1
                     sum_xa_corr = sum_xa_corr + abs_corr
                     if (abs_corr > max_abs_xa_corr_for_k) &
                        max_abs_xa_corr_for_k = abs_corr
                  else
                     num_terms = num_terms + 1
                     sum_corr = sum_corr + abs_corr
                  end if
               end do var_loop
               if (num_xa_terms > 0) then
                  num_terms = num_terms + 1
                  sum_corr = sum_corr + sum_xa_corr/num_xa_terms
               end if
            else if (s% do_burn .or. s% do_mix) then
               species_loop: do j = s% i_chem1, nvar
                  i = j - s% nvar_hydro
                  if (check_for_bad_nums) then
                     if (is_bad_num(B(j,k))) then
                        found_bad_num = .true.
                        if (report) write(*,3) 'chem B(j,k)', j, k, B(j,k)
                        if (s% stop_for_bad_nums) then
                           found_NaN = .true.
                           write(*,3) 'chem B(j,k)', j, k, B(j,k)
                           stop 'sizeB_15066'
                        max_zone = k
                        max_var = j
                        exit cell_loop
                        end if
                     end if
                  end if
                  ! recall that correction dx = B*xscale, so B is a relative correction
                  if (s% xa_start(i,k) >= x_limit) then
                     abs_corr = abs(B(j,k))
                     if (abs_corr > max_abs_corr_for_k) max_abs_corr_for_k = abs_corr
                     if (abs_corr > max_abs_correction) then
                        max_abs_correction = abs_corr
                        max_correction = B(j,k)
                        max_zone = k
                        max_var = j
                     end if
                     sum_corr = sum_corr + abs_corr
                     num_terms = num_terms + 1
                  end if
               end do species_loop
            end if
            s% max_abs_xa_corr(k) = max_abs_xa_corr_for_k
         end do cell_loop

         if (found_bad_num) then
            ierr = -1
            if (found_NaN .and. s% stop_for_bad_nums) then
               write(*,*) 'found bad num'
               stop 'sizeB_15066'
            end if
            if (.not. dbg) return
         end if

         if (is_bad_num(sum_corr)) then
            ierr = -1
            if (s% stop_for_bad_nums) then
               if (report) write(*,*) 'sum_corr', sum_corr
               stop 'sizeB_15066'
            end if
            if (.not. dbg) return
            write(*,*) 'sum_corr', sum_corr
            stop 'sizeB_15066'
         end if

         correction_norm = sum_corr/num_terms  !sqrt(sum_corr/num_terms)
         if (dbg) then
            write(*,2) 'sizeB_15066: iter, correction_norm, max_correction', &
               iter, correction_norm, max_correction
            if (max_correction > 1d50 .or. is_bad_num(correction_norm)) then
               call show_stuff
               stop 'sizeB_15066'
            end if
         end if

         if (s% solver_show_correction_info) call show_stuff

         abs_corr = max_abs_correction

         s% abs_max_corr2 = s% abs_max_corr1; s% abs_max_corr1 = abs_corr
         s% max_var2 = s% max_var1; s% max_var1 = max_var
         s% max_zone2 = s% max_zone1; s% max_zone1 = max_zone

         if (ierr /= 0) stop 'ierr in sizeB_15066'

         if (is_bad_num(max_correction)) then
            ierr = -1
            if (s% stop_for_bad_nums) then
               if (report) write(*,*) 'max_correction', max_correction
               stop 'sizeB_15066'
            end if
            if (.not. dbg) return
            write(*,*) 'max_correction', max_correction
            stop 'sizeB_15066'
         end if

         if (iter < 3) return
         ! check for flailing
         if ( &
             abs_corr > s% tol_max_correction .and. &
             abs_corr > s% abs_max_corr1 .and. s% abs_max_corr1 > s% abs_max_corr2 .and. &
             max_zone == s% max_zone1 .and. s% max_zone1 == s% max_zone2 .and. &
             max_var == s% max_var1 .and. s% max_var1 == s% max_var2) then
            if (s% solver_show_correction_info) then
               write(*,*) 'give up because diverging'
            end if
            max_correction = 1d99
         end if


         contains


         subroutine show_stuff
            integer :: j, k
            real(dp) :: dx, prev, new
            include 'formats'
            if (iter == 1) then
               write(*,*)
               write(*,'(4a7,12a16,99a13)') &
                  'model', 'iter', 'var', 'zone', &
                  'corr norm', 'max corr', 'xscale', &
                  'dx', 'new-prev', 'new', 'prev', &
                  'mass loc', 'log dt/yr', 'lgE', 'lgT', 'lgRho'
            end if
            k = max_zone
            j = max_var
            if (j > nvar_hydro) then
               prev = s% xa_start(j - nvar_hydro,k)
            else
               prev = s% xh_start(j,k)
            end if
            dx = B(j,k)*xscale(j,k)
            new = prev + dx
            write(*,'(2i7,a7,i7,12e16.8,99f13.8)') &
               s% model_number, iter, trim(s% nameofvar(max_var)), k, &
               correction_norm, B(j,k), xscale(j,k), &
               dx, new - prev, new, prev, &
               s% m(k)/Msun, log10(rpar(rpar_dt)/secyer), &
               s% lnE(k)/ln10, s% lnT(k)/ln10, &
               s% lnd(k)/ln10
         end subroutine show_stuff


         subroutine dump_B
            integer :: k, j, k0, k1
            include 'formats'
            do k=1,s% nz
               do j=1,nvar
                  write(*,2) 'B ' // trim(s% nameofequ(j)), k, B(j, k)
               end do
               write(*,*)
            end do
            stop 'dump_equ'
         end subroutine dump_B


      end subroutine sizeB_15066


      subroutine sizequ_15066( &
            iter, nvar, nz, equ, &
            equ_norm, equ_max, k_max, j_max, &
            equ_max_cv, k_max_cv, &
            lrpar, rpar, lipar, ipar, ierr)
         integer, intent(in) :: iter, nvar, nz
         real(dp), pointer :: equ(:,:) ! (nvar, nz)
         real(dp), intent(out) :: equ_norm, equ_max, equ_max_cv
         integer, intent(in) :: lrpar, lipar
         real(dp), intent(inout) :: rpar(:) ! (lrpar)
         integer, intent(inout) :: ipar(:) ! (lipar)
         integer, intent(out) :: k_max, j_max, k_max_cv, ierr

         integer :: j, k, num_terms, n, i_chem1, nvar_hydro, nvar_chem, &
            max_loc, skip_eqn1, skip_eqn2, skip_eqn3
         real(dp) :: sumequ, absq, max_energy_resid, avg_energy_resid
         type (star_info), pointer :: s
         
         logical :: dbg

         include 'formats'

         ierr = 0
         call get_star_ptr(ipar(ipar_id), s, ierr)
         if (ierr /= 0) return
         
         equ_norm = 0d0
         equ_max = 0d0
         equ_max_cv = 0d0
         k_max = 0
         j_max = 0
         k_max_cv =  0
         
         dbg = s% solver_check_everything

         nvar_hydro = min(nvar, s% nvar_hydro)
         nvar_chem = s% nvar_chem
         n = nz
         num_terms = 0
         sumequ = 0
         skip_eqn1 = 0 ! s% i_equL
         skip_eqn2 = 0 ! s% i_dln_cvpv0_dt
         skip_eqn3 = 0 ! s% i_dln_cvpv0_dt
         if (s% convergence_ignore_equL_residuals) skip_eqn1 = s% i_equL
         if (s% convergence_separate_equ_conv_vel_residuals) skip_eqn2 = s% i_dln_cvpv0_dt
         if (s% convergence_ignore_alpha_RTI_residuals) skip_eqn3 = s% i_dalpha_RTI_dt
         if (s% do_struct_hydro .or. s% do_struct_thermo) then
            if (s% do_burn .or. s% do_mix) then
               num_terms = num_terms + nvar*nz
               if (skip_eqn1 > 0) num_terms = num_terms - nz
               if (skip_eqn2 > 0) num_terms = num_terms - nz
               if (skip_eqn3 > 0) num_terms = num_terms - nz
               do k = 1, nz
                  do j = 1, nvar
                     if (j == skip_eqn1 .or. j == skip_eqn2 .or. j == skip_eqn3) cycle
                     absq = abs(equ(j,k))
                     sumequ = sumequ + absq
                     if (absq > equ_max) then
                        equ_max = absq
                        j_max = j
                        k_max = k
                     end if
                  end do
               end do
            else
               if (skip_eqn1 == 0 .and. skip_eqn2 == 0) then
                  num_terms = num_terms + nvar_hydro*nz
               else if (skip_eqn1 > 0 .and. skip_eqn2 > 0) then
                  num_terms = num_terms + (nvar_hydro-2)*nz
               else
                  num_terms = num_terms + (nvar_hydro-1)*nz
               end if
               do k = 1, nz
                  do j = 1, nvar_hydro
                     if (j == skip_eqn1 .or. j == skip_eqn2) cycle
                     absq = abs(equ(j,k))
                     !write(*,3) 'equ(j,k)', j, k, equ(j,k)
                     sumequ = sumequ + absq
                     if (is_bad(sumequ)) then
                        if (dbg) then
                           write(*,3) trim(s% nameofequ(j)) // ' sumequ', j, k, sumequ
                           stop 'sizeq'
                        end if
                        ierr = -1
                        if (s% report_ierr) &
                           write(*,3) 'bad equ(j,k) ' // trim(s% nameofequ(j)), &
                              j, k, equ(j,k)
                        if (s% stop_for_bad_nums) stop 'sizeq'
                        return
                     end if
                     if (absq > equ_max) then
                        equ_max = absq
                        j_max = j
                        k_max = k
                     end if
                  end do
               end do
            end if
         end if
         if (s% do_burn .or. s% do_mix) then
            i_chem1 = s% i_chem1
            num_terms = num_terms + nvar_chem*nz
            do k = 1, nz
               do j = i_chem1, nvar
                  absq = abs(equ(j,k))
                  sumequ = sumequ + absq
                  if (absq > equ_max) then
                     equ_max = absq
                     j_max = j
                     k_max = k
                  end if
               end do
            end do
         end if
         if (s% conv_vel_flag) then
            do k = 1, nz
               j = s% i_dln_cvpv0_dt
               absq = abs(equ(j,k))
               if (absq > equ_max_cv) then
                  equ_max_cv = absq
                  k_max_cv = k
               end if
            end do
         end if

         equ_norm = sumequ/num_terms
         if (dbg) write(*,4) trim(s% nameofequ(j_max)) // ' sizequ_15066 equ_max norm', &
            k_max, iter, s% model_number, equ_max, equ_norm
         
         if (dbg) call dump_equ
         
         return
         call dump_equ
         stop 'sizequ_15066'
         
         contains

         subroutine dump_equ
            integer :: k, j, k0, k1
            include 'formats'
            do k=1,s% nz
               do j=1,nvar
                  write(*,3) 'equ ' // trim(s% nameofequ(j)), &
                     k, iter, equ(j, k)
               end do
               write(*,*)
               !if (k == 6) exit
            end do
         end subroutine dump_equ

      end subroutine sizequ_15066


      end module star_solver_15066