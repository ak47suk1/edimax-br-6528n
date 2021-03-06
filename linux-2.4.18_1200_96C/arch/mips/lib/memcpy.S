/*
 * This file is subject to the terms and conditions of the GNU General Public
 * License.  See the file "COPYING" in the main directory of this archive
 * for more details.
 *
 * Unified implementation of memcpy, memmove and the __copy_user backend.
 *
 * Copyright (C) 1998, 99, 2000, 01, 2002 Ralf Baechle (ralf@gnu.org)
 * Copyright (C) 1999, 2000, 01, 2002 Silicon Graphics, Inc.
 * Copyright (C) 2002 Broadcom, Inc.
 *   memcpy/copy_user author: Mark Vandevoorde
 *
 * Mnemonic names for arguments to memcpy/__copy_user
 */
#include <asm/asm.h>
#include <asm/offset.h>
#include <asm/regdef.h>
#include <linux/autoconf.h>

//kenny
//#define USE_LX_DSP

#define dst a0
#define src a1
#define len a2

/*
 * Spec
 *
 * memcpy copies len bytes from src to dst and sets v0 to dst.
 * It assumes that
 *   - src and dst don't overlap
 *   - src is readable
 *   - dst is writable
 * memcpy uses the standard calling convention
 *
 * __copy_user copies up to len bytes from src to dst and sets a2 (len) to
 * the number of uncopied bytes due to an exception caused by a read or write.
 * __copy_user assumes that src and dst don't overlap, and that the call is
 * implementing one of the following:
 *   copy_to_user
 *     - src is readable  (no exceptions when reading src)
 *   copy_from_user
 *     - dst is writable  (no exceptions when writing dst)
 * __copy_user uses a non-standard calling convention; see
 * include/asm-mips/uaccess.h
 *
 * When an exception happens on a load, the handler must
 # ensure that all of the destination buffer is overwritten to prevent
 * leaking information to user mode programs.
 */

/*
 * Implementation
 */

/*
 * The exception handler for loads requires that:
 *  1- AT contain the address of the byte just past the end of the source
 *     of the copy,
 *  2- src_entry <= src < AT, and
 *  3- (dst - src) == (dst_entry - src_entry),
 * The _entry suffix denotes values when __copy_user was called.
 *
 * (1) is set up up by uaccess.h and maintained by not writing AT in copy_user
 * (2) is met by incrementing src by the number of bytes copied
 * (3) is met by not doing loads between a pair of increments of dst and src
 *
 * The exception handlers for stores adjust len (if necessary) and return.
 * These handlers do not need to overwrite any data.
 *
 * For __rmemcpy and memmove an exception is always a kernel bug, therefore
 * they're not protected.
 */

#define EXC(inst_reg,addr,handler)		\
9:	inst_reg, addr;				\
	.section __ex_table,"a";		\
	PTR	9b, handler;			\
	.previous

/*
 * In the mips (not mips64) tree, so we can't use doubles
 */

#define LOAD   lw
#define STORE  sw
#define ADD    addu
#define SUB    subu
#define SRL    srl
#define SLL    sll
#define SRA    sra
#define SLLV   sllv
#define SRLV   srlv
#define NBYTES 4
#define LOG_NBYTES 2


#ifdef CONFIG_CPU_LITTLE_ENDIAN
#define SHIFT_DISCARD SLLV
#else
#define SHIFT_DISCARD SRLV
#endif

#define FIRST(unit) ((unit)*NBYTES)
#define REST(unit)  (FIRST(unit)+NBYTES-1)
#define UNIT(unit)  FIRST(unit)

#ifdef USE_LX_DSP		
#define ADDRMASK_7 7
#endif
#define ADDRMASK (NBYTES-1)

	.text
	.set	noreorder
	.set	noat

/*
 * A combined memcpy/__copy_user
 * __copy_user sets len to 0 for success; else to an upper bound of
 * the number of uncopied bytes.
 * memcpy sets v0 to dst.
 */
	.align	5
LEAF(memcpy)					/* a0=dst a1=src a2=len */
	move	v0, dst				/* return value */
__memcpy:
FEXPORT(__copy_user)
	/*
	 * Note: dst & src may be unaligned, len may be 0
	 * Temps
	 */
#define rem t8

	/*
	 * The "issue break"s below are very approximate.
	 * Issue delays for dcache fills will perturb the schedule, as will
	 * load queue full replay traps, etc.
	 *
	 * If len < NBYTES use byte operations.
	 */
	sltu	t2, len, NBYTES
	and	t1, dst, ADDRMASK
	bnez	t2, copy_bytes_checklen
	and t2, src, ADDRMASK
	bnez t1, copy_bytes_checklen
	nop
	bnez t2, copy_bytes_checklen
	nop


#ifdef USE_LX_DSP
	// Now both src and dst are 4-byte aligned, further check if 8-byte aligned?
/*
	and		t1, dst, ADDRMASK_7
	bnez	t1, both_aligned
	and		t2, src, ADDRMASK_7
	bnez	t2, both_aligned
	nop		// can't removed
*/
	and		t1, dst, ADDRMASK_7
	and		t2, src, ADDRMASK_7
	bne		t1, t2, both_aligned
	nop
	beq		t1, $0, both_8byte_aligned;
	nop 
both_4byte_aligned:	# but not 8byte aligned
EXC(	LOAD	t0, UNIT(0)(src),	l_exc)
	SUB	len, len, NBYTES
EXC(	STORE	t0, UNIT(0)(dst),	s_exc_p8u)
	ADD	src, src, NBYTES
	ADD	dst, dst, NBYTES	
	
both_8byte_aligned:
	// Now both src and dst are 8-byte aligned
	// t5, t6, t8 can't be used
	// Zero overhead loop doesn't work!

	SRL		t0, len, LOG_NBYTES+3    # +3 for 8 units/iter
	beqz	t0, cleanup_both_8byte_aligned # len < 8*NBYTES
	 and		rem, len, (8*NBYTES-1)	 # rem = len % (8*NBYTES)
	.align	4
1:
EXC(	lt		t0, UNIT(0)(src),	l_exc)
EXC(	lt		t2, UNIT(2)(src),	l_exc_copy)
	SUB	len, len, 8*NBYTES
EXC(	st		t0, UNIT(0)(dst),	s_exc_p8u)
EXC(	LOAD	t4, UNIT(4)(src),	l_exc_copy)
EXC(	LOAD	t7, UNIT(5)(src),	l_exc_copy)
EXC(	lt		t0, UNIT(6)(src),	l_exc_copy)
	ADD	src, src, 8*NBYTES
	ADD	dst, dst, 8*NBYTES
EXC(	st		t2, UNIT(-6)(dst),	s_exc_p6u)
EXC(	STORE	t4, UNIT(-4)(dst),	s_exc_p4u)
EXC(	STORE	t7, UNIT(-3)(dst),	s_exc_p3u)
EXC(	st		t0, UNIT(-2)(dst),	s_exc_p2u)
	bne	len, rem, 1b
	 nop

	# cleanup_both_8byte_aligned
	/*
	 * len == rem == the number of bytes left to copy < 8*NBYTES
	 */
cleanup_both_8byte_aligned:
	beqz	len, done
	 sltu	t0, len, 4*NBYTES
	bnez	t0, less_than_4units
	 and	rem, len, (NBYTES-1)	# rem = len % NBYTES
	/*
	 * len >= 4*NBYTES
	 */
EXC(	lt		t0, UNIT(0)(src),	l_exc)
EXC(	lt		t2, UNIT(2)(src),	l_exc_copy)
	SUB	len, len, 4*NBYTES
	ADD	src, src, 4*NBYTES
EXC(	st		t0, UNIT(0)(dst),	s_exc_p4u)
EXC(	st		t2, UNIT(2)(dst),	s_exc_p2u)
	beqz	len, done
	 ADD	dst, dst, 4*NBYTES	
	 
	j less_than_4units
	 nop
	
#endif /* USE_LX_DSP */

	/*
	 * use delay slot for fall-through
	 * src and dst are aligned; need to compute rem
	 */
both_aligned:
	 SRL	t0, len, LOG_NBYTES+3    # +3 for 8 units/iter
	beqz	t0, cleanup_both_aligned # len < 8*NBYTES
	 and	rem, len, (8*NBYTES-1)	 # rem = len % (8*NBYTES)
	.align	4
1:
EXC(	LOAD	t0, UNIT(0)(src),	l_exc)
EXC(	LOAD	t1, UNIT(1)(src),	l_exc_copy)
EXC(	LOAD	t2, UNIT(2)(src),	l_exc_copy)
EXC(	LOAD	t3, UNIT(3)(src),	l_exc_copy)
	SUB	len, len, 8*NBYTES
EXC(	LOAD	t4, UNIT(4)(src),	l_exc_copy)
EXC(	LOAD	t7, UNIT(5)(src),	l_exc_copy)
EXC(	STORE	t0, UNIT(0)(dst),	s_exc_p8u)
EXC(	STORE	t1, UNIT(1)(dst),	s_exc_p7u)
EXC(	LOAD	t0, UNIT(6)(src),	l_exc_copy)
EXC(	LOAD	t1, UNIT(7)(src),	l_exc_copy)
	ADD	src, src, 8*NBYTES
	ADD	dst, dst, 8*NBYTES
EXC(	STORE	t2, UNIT(-6)(dst),	s_exc_p6u)
EXC(	STORE	t3, UNIT(-5)(dst),	s_exc_p5u)
EXC(	STORE	t4, UNIT(-4)(dst),	s_exc_p4u)
EXC(	STORE	t7, UNIT(-3)(dst),	s_exc_p3u)
EXC(	STORE	t0, UNIT(-2)(dst),	s_exc_p2u)
EXC(	STORE	t1, UNIT(-1)(dst),	s_exc_p1u)
	bne	len, rem, 1b
	 nop

	/*
	 * len == rem == the number of bytes left to copy < 8*NBYTES
	 */
cleanup_both_aligned:
	beqz	len, done
	 sltu	t0, len, 4*NBYTES
	bnez	t0, less_than_4units
	 and	rem, len, (NBYTES-1)	# rem = len % NBYTES
	/*
	 * len >= 4*NBYTES
	 */
EXC(	LOAD	t0, UNIT(0)(src),	l_exc)
EXC(	LOAD	t1, UNIT(1)(src),	l_exc_copy)
EXC(	LOAD	t2, UNIT(2)(src),	l_exc_copy)
EXC(	LOAD	t3, UNIT(3)(src),	l_exc_copy)
	SUB	len, len, 4*NBYTES
	ADD	src, src, 4*NBYTES
EXC(	STORE	t0, UNIT(0)(dst),	s_exc_p4u)
EXC(	STORE	t1, UNIT(1)(dst),	s_exc_p3u)
EXC(	STORE	t2, UNIT(2)(dst),	s_exc_p2u)
EXC(	STORE	t3, UNIT(3)(dst),	s_exc_p1u)
	beqz	len, done
	 ADD	dst, dst, 4*NBYTES
less_than_4units:
	/*
	 * rem = len % NBYTES
	 */
	beq	rem, len, copy_bytes
	 nop
#ifdef USE_LX_DSP_XX
1:
EXC(	lwp	 t0, (src)NBYTES,		l_exc)
	SUB	len, len, NBYTES
EXC(	STORE	t0, 0(dst),		s_exc)
	bne	rem, len, 1b
	 ADD	dst, dst, NBYTES
#else	 
1:
EXC(	LOAD	 t0, 0(src),		l_exc)
	ADD	src, src, NBYTES
	SUB	len, len, NBYTES
EXC(	STORE	t0, 0(dst),		s_exc)
	bne	rem, len, 1b
	 ADD	dst, dst, NBYTES
#endif
copy_bytes_checklen:
	beqz	len, done
	 nop
copy_bytes:
#ifdef USE_LX_DSP_XX
1:
	beqz	len, done
	nop
EXC(	lbp  t0, (src)1, l_exc)
	SUB len, len, 1
EXC(	sbp	 t0, (dst)1, s_exc_p1)
	bnez	len, 1b 
	nop
#else
1:
	beqz	len, done
	nop
EXC(	lb  t0, 0(src), l_exc)
	SUB len, len, 1
EXC(	sb	t0, 0(dst), s_exc_p1)
	ADD	dst,	dst, 1
	ADD src,	src, 1
	bnez	len, 1b 
	nop
#endif /* USE_LX_DSP */	
done:
	jr	ra
	 nop
	END(memcpy)

l_exc_copy:
	/*
	 * Copy bytes from src until faulting load address (or until a
	 * lb faults)
	 *
	 * When reached by a faulting LDFIRST/LDREST, THREAD_BUADDR($28)
	 * may be more than a byte beyond the last address.
	 * Hence, the lb below may get an exception.
	 *
	 * Assumes src < THREAD_BUADDR($28)
	 */
	lw	t0, THREAD_BUADDR($28)
1:
EXC(	lb	t1, 0(src),	l_exc)
	ADD	src, src, 1
	sb	t1, 0(dst)	# can't fault -- we're copy_from_user
	bne	src, t0, 1b
	 ADD	dst, dst, 1
l_exc:
	lw	t0, THREAD_BUADDR($28)	# t0 is just past last good address
	 nop
	subu	len, AT, t0		# len number of uncopied bytes
	/*
	 * Here's where we rely on src and dst being incremented in tandem,
	 *   See (3) above.
	 * dst += (fault addr - src) to put dst at first byte to clear
	 */
	addu	dst, t0			# compute start address in a1
	subu	dst, src
	/*
	 * Clear len bytes starting at dst.  Can't call __bzero because it
	 * might modify len.  An inefficient loop for these rare times...
	 */
	beqz	len, done
	 SUB	src, len, 1
1:	sb	zero, 0(dst)
	ADD	dst, dst, 1
	bnez	src, 1b
	 SUB	src, src, 1
	jr	ra
	 nop


#define SEXC(n)				\
s_exc_p ## n ## u:			\
	jr	ra;			\
	 ADD	len, len, n*NBYTES

SEXC(8)
SEXC(7)
SEXC(6)
SEXC(5)
SEXC(4)
SEXC(3)
SEXC(2)
SEXC(1)

s_exc_p1:
	jr	ra
	 ADD	len, len, 1
s_exc:
	jr	ra
	 nop

	.align	5
LEAF(memmove)
	addu	t0, a0, a2
	addu	t1, a1, a2
	sltu	t0, a1, t0			# dst + len <= src -> memcpy
	sltu	t1, a0, t1			# dst >= src + len -> memcpy
	and	t0, t1
	beqz	t0, __memcpy
	 move	v0, a0				/* return value */
	beqz	a2, r_out
	END(memmove)

	/* fall through to __rmemcpy */
LEAF(__rmemcpy)					/* a0=dst a1=src a2=len */
	 sltu	t0, a1, a0
	beqz	t0, r_end_bytes_up		# src >= dst
	 nop
	addu	a0, a2				# dst = dst + len
	addu	a1, a2				# src = src + len

r_end_bytes:
	lb	t0, -1(a1)
	subu	a2, a2, 0x1
	sb	t0, -1(a0)
	subu	a1, a1, 0x1
	bnez	a2, r_end_bytes
	 subu	a0, a0, 0x1

r_out:
	jr	ra
	 move	a2, zero

r_end_bytes_up:
	lb	t0, (a1)
	subu	a2, a2, 0x1
	sb	t0, (a0)
	addu	a1, a1, 0x1
	bnez	a2, r_end_bytes_up
	 addu	a0, a0, 0x1

	jr	ra
	 move	a2, zero
	END(__rmemcpy)
