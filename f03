From jaegeuk.kim@samsung.com Mon Oct 22 19:27:10 2012
From: Jaegeuk Kim <jaegeuk.kim@samsung.com>
Date: Tue, 23 Oct 2012 11:26:49 +0900
Subject: [PATCH 03/16 v2] f2fs: add superblock and major in-memory structure
To: linux-fsdevel@vger.kernel.org, linux-kernel@vger.kernel.org, gregkh@linuxfoundation.org, viro@zeniv.linux.org.uk, arnd@arndb.de, tytso@mit.edu, chur.lee@samsung.com, cm224.lee@samsung.com, jooyoung.hwang@samsung.com
Message-ID: <001301cdb0c5$db3175b0$91946110$%kim@samsung.com>


This adds the following major in-memory structures in f2fs.

- f2fs_sb_info:
  contains f2fs-specific information, two special inode pointers for node and
  meta address spaces, and orphan inode management.

- f2fs_inode_info:
  contains vfs_inode and other fs-specific information.

- f2fs_nm_info:
  contains node manager information such as NAT entry cache, free nid list,
  and NAT page management.

- f2fs_node_info:
  represents a node as node id, inode number, block address, and its version.

- f2fs_sm_info:
  contains segment manager information such as SIT entry cache, free segment
  map, current active logs, dirty segment management, and segment utilization.
  The specific structures are sit_info, free_segmap_info, dirty_seglist_info,
  curseg_info.

Signed-off-by: Chul Lee <chur.lee@samsung.com>
Signed-off-by: Jaegeuk Kim <jaegeuk.kim@samsung.com>
---
 fs/f2fs/f2fs.h    |  982 +++++++++++++++++++++++++++++++++++++++++++++++++++++
 fs/f2fs/node.h    |  330 ++++++++++++++++++
 fs/f2fs/segment.h |  594 ++++++++++++++++++++++++++++++++
 3 files changed, 1906 insertions(+)
 create mode 100644 fs/f2fs/f2fs.h
 create mode 100644 fs/f2fs/node.h
 create mode 100644 fs/f2fs/segment.h

diff --git a/fs/f2fs/f2fs.h b/fs/f2fs/f2fs.h
new file mode 100644
index 0000000..bbe2f02
--- /dev/null
+++ b/fs/f2fs/f2fs.h
@@ -0,0 +1,982 @@
+/**
+ * fs/f2fs/f2fs.h
+ *
+ * Copyright (c) 2012 Samsung Electronics Co., Ltd.
+ *             http://www.samsung.com/
+ *
+ * This program is free software; you can redistribute it and/or modify
+ * it under the terms of the GNU General Public License version 2 as
+ * published by the Free Software Foundation.
+ */
+#ifndef _LINUX_F2FS_H
+#define _LINUX_F2FS_H
+
+#include <linux/types.h>
+#include <linux/page-flags.h>
+#include <linux/buffer_head.h>
+#include <linux/version.h>
+#include <linux/slab.h>
+#include <linux/crc32.h>
+
+/**
+ * For mount options
+ */
+#define F2FS_MOUNT_BG_GC		0x00000001
+#define F2FS_MOUNT_DISABLE_ROLL_FORWARD	0x00000002
+#define F2FS_MOUNT_DISCARD		0x00000004
+#define F2FS_MOUNT_NOHEAP		0x00000008
+#define F2FS_MOUNT_XATTR_USER		0x00000010
+#define F2FS_MOUNT_POSIX_ACL		0x00000020
+#define F2FS_MOUNT_DISABLE_EXT_IDENTIFY	0x00000040
+
+#define clear_opt(sbi, option)	(sbi->mount_opt.opt &= ~F2FS_MOUNT_##option)
+#define set_opt(sbi, option)	(sbi->mount_opt.opt |= F2FS_MOUNT_##option)
+#define test_opt(sbi, option)	(sbi->mount_opt.opt & F2FS_MOUNT_##option)
+
+#define ver_after(a, b)	(typecheck(unsigned long long, a) &&		\
+		typecheck(unsigned long long, b) &&			\
+		((long long)((a) - (b)) > 0))
+
+typedef u64 block_t;
+typedef u32 nid_t;
+
+struct f2fs_mount_info {
+	unsigned int	opt;
+};
+
+static inline __u32 f2fs_crc32(void *buff, size_t len)
+{
+	return crc32_le(F2FS_SUPER_MAGIC, buff, len);
+}
+
+static inline bool f2fs_crc_valid(__u32 blk_crc, void *buff, size_t buff_size)
+{
+	return f2fs_crc32(buff, buff_size) == blk_crc;
+}
+
+/**
+ * For checkpoint manager
+ */
+#define CP_ERROR_FLAG		0x00000008
+#define CP_COMPACT_SUM_FLAG	0x00000004
+#define CP_ORPHAN_PRESENT_FLAG	0x00000002
+#define CP_UMOUNT_FLAG		0x00000001
+
+enum {
+	NAT_BITMAP,
+	SIT_BITMAP
+};
+
+struct orphan_inode_entry {
+	struct list_head list;
+	nid_t ino;
+};
+
+struct dir_inode_entry {
+	struct list_head list;
+	struct inode *inode;
+};
+
+struct fsync_inode_entry {
+	struct list_head list;
+	struct inode *inode;
+	block_t blkaddr;
+};
+
+#define nats_in_cursum(sum)		(le16_to_cpu(sum->n_nats))
+#define sits_in_cursum(sum)		(le16_to_cpu(sum->n_sits))
+
+#define nat_in_journal(sum, i)		(sum->nat_j.entries[i].ne)
+#define nid_in_journal(sum, i)		(sum->nat_j.entries[i].nid)
+#define sit_in_journal(sum, i)		(sum->sit_j.entries[i].se)
+#define segno_in_journal(sum, i)	(sum->sit_j.entries[i].segno)
+
+static inline int update_nats_in_cursum(struct f2fs_summary_block *rs, int i)
+{
+	int before = nats_in_cursum(rs);
+	rs->n_nats = cpu_to_le16(before + i);
+	return before;
+}
+
+static inline int update_sits_in_cursum(struct f2fs_summary_block *rs, int i)
+{
+	int before = sits_in_cursum(rs);
+	rs->n_sits = cpu_to_le16(before + i);
+	return before;
+}
+
+/**
+ * For INODE and NODE manager
+ */
+#define XATTR_NODE_OFFSET	(-1)
+#define RDONLY_NODE		1
+#define F2FS_LINK_MAX		32000
+
+struct extent_info {
+	rwlock_t ext_lock;
+	unsigned int fofs;
+	u32 blk_addr;
+	unsigned int len;
+};
+
+#define FADVISE_COLD_BIT	0x01
+/*
+ * i_advise uses FADVISE_XXX_BIT. We can add additional hints later.
+ */
+struct f2fs_inode_info {
+	struct inode vfs_inode;
+	unsigned long i_flags;
+	unsigned long flags;
+	unsigned long long data_version;
+	atomic_t dirty_dents;
+	unsigned int current_depth;
+	f2fs_hash_t chash;
+	unsigned int clevel;
+	nid_t i_xattr_nid;
+	struct extent_info ext;
+	umode_t i_acl_mode;
+	unsigned char i_advise;		/* If true, this is cold data */
+};
+
+static inline void get_extent_info(struct extent_info *ext,
+					struct f2fs_extent i_ext)
+{
+	write_lock(&ext->ext_lock);
+	ext->fofs = le32_to_cpu(i_ext.fofs);
+	ext->blk_addr = le32_to_cpu(i_ext.blk_addr);
+	ext->len = le32_to_cpu(i_ext.len);
+	write_unlock(&ext->ext_lock);
+}
+
+static inline void set_raw_extent(struct extent_info *ext,
+					struct f2fs_extent *i_ext)
+{
+	read_lock(&ext->ext_lock);
+	i_ext->fofs = cpu_to_le32(ext->fofs);
+	i_ext->blk_addr = cpu_to_le32(ext->blk_addr);
+	i_ext->len = cpu_to_le32(ext->len);
+	read_unlock(&ext->ext_lock);
+}
+
+struct f2fs_nm_info {
+	block_t nat_blkaddr;		/* base disk address of NAT */
+	unsigned int nat_segs;		/* the number of nat segments */
+	unsigned int nat_blocks;	/* the number of nat blocks of
+					   one size */
+	nid_t max_nid;
+	unsigned int nat_cnt;		/* the number of nodes in NAT Buffer */
+	struct radix_tree_root nat_root;
+	rwlock_t nat_tree_lock;		/* Protect nat_tree_lock */
+	struct list_head nat_entries;	/* cached nat entry list (clean) */
+	struct list_head dirty_nat_entries; /* cached nat entry list (dirty) */
+
+	unsigned int fcnt;		/* the number of free node id */
+	struct mutex build_lock;	/* lock for build free nids */
+
+	int nat_upd_blkoff[3];		/* Block offset
+					   in the current journal segment
+					   where the last NAT update happened */
+	int lst_upd_blkoff[3];		/* Block offset
+					   in current journal segment */
+
+	unsigned int written_valid_node_count;
+	unsigned int written_valid_inode_count;
+	char *nat_bitmap;		/* NAT bitmap pointer */
+	int bitmap_size;		/* bitmap size */
+
+	nid_t init_scan_nid;		/* the first nid to be scanned */
+	nid_t next_scan_nid;		/* the next nid to be scanned */
+	struct list_head free_nid_list;
+	spinlock_t free_nid_list_lock;	/* Protect free nid list */
+};
+
+struct dnode_of_data {
+	struct inode *inode;
+	struct page *inode_page;
+	struct page *node_page;
+	nid_t nid;
+	unsigned int ofs_in_node;
+	bool inode_page_locked;
+	block_t	data_blkaddr;
+};
+
+static inline void set_new_dnode(struct dnode_of_data *dn, struct inode *inode,
+		struct page *ipage, struct page *npage, nid_t nid)
+{
+	dn->inode = inode;
+	dn->inode_page = ipage;
+	dn->node_page = npage;
+	dn->nid = nid;
+	dn->inode_page_locked = 0;
+}
+
+/**
+ * For SIT manager
+ */
+#define	NR_CURSEG_DATA_TYPE	(3)
+#define NR_CURSEG_NODE_TYPE	(3)
+#define NR_CURSEG_TYPE	(NR_CURSEG_DATA_TYPE + NR_CURSEG_NODE_TYPE)
+
+enum {
+	CURSEG_HOT_DATA = 0,
+	CURSEG_WARM_DATA,
+	CURSEG_COLD_DATA,
+	CURSEG_HOT_NODE,
+	CURSEG_WARM_NODE,
+	CURSEG_COLD_NODE,
+	NO_CHECK_TYPE
+};
+
+struct f2fs_sm_info {
+	/* SIT information */
+	struct sit_info *sit_info;
+
+	/* Free segmap infomation */
+	struct free_segmap_info *free_info;
+
+	/* Dirty segments list information for GC victim */
+	struct dirty_seglist_info *dirty_info;
+
+	/* Current working segments(i.e. logging point) information array */
+	struct curseg_info *curseg_array;
+
+	/* list head of all under-writeback pages for flush handling */
+	struct list_head	wblist_head;
+	spinlock_t		wblist_lock;
+
+	block_t			seg0_blkaddr;
+	block_t			main_blkaddr;
+	unsigned int		segment_count;
+	unsigned int		rsvd_segment_count;
+	unsigned int		main_segment_count;
+	block_t			ssa_blkaddr;
+	unsigned int		segment_count_ssa;
+};
+
+/**
+ * For Garbage Collection
+ */
+struct f2fs_gc_info {
+#ifdef CONFIG_F2FS_STAT_FS
+	struct list_head	stat_list;
+	struct f2fs_stat_info	*stat_info;
+#endif
+	int			cause;
+	int			rsvd_segment_count;
+	int			overp_segment_count;
+};
+
+/**
+ * For directory operation
+ */
+#define F2FS_INODE_SIZE		(17 * 4 + F2FS_MAX_NAME_LEN)
+#define	NODE_DIR1_BLOCK		(ADDRS_PER_INODE + 1)
+#define	NODE_DIR2_BLOCK		(ADDRS_PER_INODE + 2)
+#define	NODE_IND1_BLOCK		(ADDRS_PER_INODE + 3)
+#define	NODE_IND2_BLOCK		(ADDRS_PER_INODE + 4)
+#define	NODE_DIND_BLOCK		(ADDRS_PER_INODE + 5)
+
+/**
+ * For superblock
+ */
+enum count_type {
+	F2FS_WRITEBACK,
+	F2FS_DIRTY_DENTS,
+	F2FS_DIRTY_NODES,
+	F2FS_DIRTY_META,
+	NR_COUNT_TYPE,
+};
+
+/*
+ * FS_LOCK nesting subclasses for the lock validator:
+ *
+ * The locking order between these classes is
+ * RENAME -> DENTRY_OPS -> DATA_WRITE -> DATA_NEW
+ *    -> DATA_TRUNC -> NODE_WRITE -> NODE_NEW -> NODE_TRUNC
+ */
+enum lock_type {
+	RENAME,		/* for renaming operations */
+	DENTRY_OPS,	/* for directory operations */
+	DATA_WRITE,	/* for data write */
+	DATA_NEW,	/* for data allocation */
+	DATA_TRUNC,	/* for data truncate */
+	NODE_NEW,	/* for node allocation */
+	NODE_TRUNC,	/* for node truncate */
+	NODE_WRITE,	/* for node write */
+	NR_LOCK_TYPE,
+};
+
+/*
+ * The below are the page types of bios used in submti_bio().
+ * The available types are:
+ * DATA			User data pages. It operates as async mode.
+ * NODE			Node pages. It operates as async mode.
+ * META			FS metadata pages such as SIT, NAT, CP.
+ * NR_PAGE_TYPE		The number of page types.
+ * META_FLUSH		Make sure the previous pages are written
+ *			with waiting the bio's completion
+ * ...			Only can be used with META.
+ */
+enum page_type {
+	DATA,
+	NODE,
+	META,
+	NR_PAGE_TYPE,
+	META_FLUSH,
+};
+
+struct f2fs_sb_info {
+	struct super_block *sb;			/* Pointer to VFS super block */
+	int s_dirty;
+	struct f2fs_super_block *raw_super;	/* Pointer to the super block
+						   in the buffer */
+	struct buffer_head *raw_super_buf;	/* Buffer containing
+						   the f2fs raw super block */
+	struct f2fs_checkpoint *ckpt;		/* Pointer to the checkpoint
+						   in the buffer */
+	struct mutex orphan_inode_mutex;
+	spinlock_t dir_inode_lock;
+	struct mutex cp_mutex;
+	/* orphan Inode list to be written in Journal block during CP  */
+	struct list_head orphan_inode_list;
+	struct list_head dir_inode_list;
+	unsigned int n_orphans, n_dirty_dirs;
+
+	unsigned int log_sectorsize;
+	unsigned int log_sectors_per_block;
+	unsigned int log_blocksize;
+	unsigned int blocksize;
+	unsigned int root_ino_num;		/* Root Inode Number*/
+	unsigned int node_ino_num;		/* Root Inode Number*/
+	unsigned int meta_ino_num;		/* Root Inode Number*/
+	unsigned int log_blocks_per_seg;
+	unsigned int blocks_per_seg;
+	unsigned int segs_per_sec;
+	unsigned int secs_per_zone;
+	unsigned int total_sections;
+	unsigned int total_node_count;
+	unsigned int total_valid_node_count;
+	unsigned int total_valid_inode_count;
+	unsigned int segment_count[2];
+	unsigned int block_count[2];
+	unsigned int last_victim[2];
+	int active_logs;
+	block_t user_block_count;
+	block_t total_valid_block_count;
+	block_t alloc_valid_block_count;
+	block_t last_valid_block_count;
+	atomic_t nr_pages[NR_COUNT_TYPE];
+
+	struct f2fs_mount_info mount_opt;
+
+	/* related to NM */
+	struct f2fs_nm_info *nm_info;		/* Node Manager information */
+
+	/* related to SM */
+	struct f2fs_sm_info *sm_info;		/* Segment Manager
+						   information */
+	int total_hit_ext, read_hit_ext;
+	int rr_flush;
+
+	/* related to GC */
+	struct proc_dir_entry *s_proc;
+	struct f2fs_gc_info *gc_info;		/* Garbage Collector
+						   information */
+	struct mutex gc_mutex;			/* mutex for GC */
+	struct mutex fs_lock[NR_LOCK_TYPE];	/* mutex for GP */
+	struct mutex write_inode;		/* mutex for write inode */
+	struct mutex writepages;		/* mutex for writepages() */
+	struct f2fs_gc_kthread	*gc_thread;	/* GC thread */
+	int bg_gc;
+	int last_gc_status;
+	int por_doing;
+
+	struct inode *node_inode;
+	struct inode *meta_inode;
+
+	struct bio *bio[NR_PAGE_TYPE];
+	sector_t last_block_in_bio[NR_PAGE_TYPE];
+	struct rw_semaphore bio_sem;
+	spinlock_t stat_lock;			/* lock for handling the number
+						   of valid blocks and
+						   valid nodes */
+};
+
+/**
+ * Inline functions
+ */
+static inline struct f2fs_inode_info *F2FS_I(struct inode *inode)
+{
+	return container_of(inode, struct f2fs_inode_info, vfs_inode);
+}
+
+static inline struct f2fs_sb_info *F2FS_SB(struct super_block *sb)
+{
+	return sb->s_fs_info;
+}
+
+static inline struct f2fs_super_block *F2FS_RAW_SUPER(struct f2fs_sb_info *sbi)
+{
+	return (struct f2fs_super_block *)(sbi->raw_super);
+}
+
+static inline struct f2fs_checkpoint *F2FS_CKPT(struct f2fs_sb_info *sbi)
+{
+	return (struct f2fs_checkpoint *)(sbi->ckpt);
+}
+
+static inline struct f2fs_nm_info *NM_I(struct f2fs_sb_info *sbi)
+{
+	return (struct f2fs_nm_info *)(sbi->nm_info);
+}
+
+static inline struct f2fs_sm_info *SM_I(struct f2fs_sb_info *sbi)
+{
+	return (struct f2fs_sm_info *)(sbi->sm_info);
+}
+
+static inline struct sit_info *SIT_I(struct f2fs_sb_info *sbi)
+{
+	return (struct sit_info *)(SM_I(sbi)->sit_info);
+}
+
+static inline struct free_segmap_info *FREE_I(struct f2fs_sb_info *sbi)
+{
+	return (struct free_segmap_info *)(SM_I(sbi)->free_info);
+}
+
+static inline struct dirty_seglist_info *DIRTY_I(struct f2fs_sb_info *sbi)
+{
+	return (struct dirty_seglist_info *)(SM_I(sbi)->dirty_info);
+}
+
+static inline void F2FS_SET_SB_DIRT(struct f2fs_sb_info *sbi)
+{
+	sbi->s_dirty = 1;
+}
+
+static inline void F2FS_RESET_SB_DIRT(struct f2fs_sb_info *sbi)
+{
+	sbi->s_dirty = 0;
+}
+
+static inline void mutex_lock_op(struct f2fs_sb_info *sbi, enum lock_type t)
+{
+	mutex_lock_nested(&sbi->fs_lock[t], t);
+}
+
+static inline void mutex_unlock_op(struct f2fs_sb_info *sbi, enum lock_type t)
+{
+	mutex_unlock(&sbi->fs_lock[t]);
+}
+
+/**
+ * Check whether the given nid is within node id range.
+ */
+static inline void check_nid_range(struct f2fs_sb_info *sbi, nid_t nid)
+{
+	BUG_ON((nid >= NM_I(sbi)->max_nid));
+}
+
+#define F2FS_DEFAULT_ALLOCATED_BLOCKS	1
+
+/**
+ * Check whether the inode has blocks or not
+ */
+static inline int F2FS_HAS_BLOCKS(struct inode *inode)
+{
+	if (F2FS_I(inode)->i_xattr_nid)
+		return (inode->i_blocks > F2FS_DEFAULT_ALLOCATED_BLOCKS + 1);
+	else
+		return (inode->i_blocks > F2FS_DEFAULT_ALLOCATED_BLOCKS);
+}
+
+static inline bool inc_valid_block_count(struct f2fs_sb_info *sbi,
+				 struct inode *inode, blkcnt_t count)
+{
+	block_t	valid_block_count;
+
+	spin_lock(&sbi->stat_lock);
+	valid_block_count =
+		sbi->total_valid_block_count + (block_t)count;
+	if (valid_block_count > sbi->user_block_count) {
+		spin_unlock(&sbi->stat_lock);
+		return false;
+	}
+	inode->i_blocks += count;
+	sbi->total_valid_block_count = valid_block_count;
+	sbi->alloc_valid_block_count += (block_t)count;
+	spin_unlock(&sbi->stat_lock);
+	return true;
+}
+
+static inline int dec_valid_block_count(struct f2fs_sb_info *sbi,
+						struct inode *inode,
+						blkcnt_t count)
+{
+	spin_lock(&sbi->stat_lock);
+	BUG_ON(sbi->total_valid_block_count < (block_t) count);
+	BUG_ON(inode->i_blocks < count);
+	inode->i_blocks -= count;
+	sbi->total_valid_block_count -= (block_t)count;
+	spin_unlock(&sbi->stat_lock);
+	return 0;
+}
+
+static inline void inc_page_count(struct f2fs_sb_info *sbi, int count_type)
+{
+	atomic_inc(&sbi->nr_pages[count_type]);
+	F2FS_SET_SB_DIRT(sbi);
+}
+
+static inline void inode_inc_dirty_dents(struct inode *inode)
+{
+	atomic_inc(&F2FS_I(inode)->dirty_dents);
+}
+
+static inline void dec_page_count(struct f2fs_sb_info *sbi, int count_type)
+{
+	atomic_dec(&sbi->nr_pages[count_type]);
+}
+
+static inline void inode_dec_dirty_dents(struct inode *inode)
+{
+	atomic_dec(&F2FS_I(inode)->dirty_dents);
+}
+
+static inline int get_pages(struct f2fs_sb_info *sbi, int count_type)
+{
+	return atomic_read(&sbi->nr_pages[count_type]);
+}
+
+static inline block_t valid_user_blocks(struct f2fs_sb_info *sbi)
+{
+	block_t ret;
+	spin_lock(&sbi->stat_lock);
+	ret = sbi->total_valid_block_count;
+	spin_unlock(&sbi->stat_lock);
+	return ret;
+}
+
+static inline unsigned long __bitmap_size(struct f2fs_sb_info *sbi, int flag)
+{
+	struct f2fs_checkpoint *ckpt = F2FS_CKPT(sbi);
+
+	/* return NAT or SIT bitmap */
+	if (flag == NAT_BITMAP)
+		return le32_to_cpu(ckpt->nat_ver_bitmap_bytesize);
+	else if (flag == SIT_BITMAP)
+		return le32_to_cpu(ckpt->sit_ver_bitmap_bytesize);
+
+	return 0;
+}
+
+static inline void *__bitmap_ptr(struct f2fs_sb_info *sbi, int flag)
+{
+	struct f2fs_checkpoint *ckpt = F2FS_CKPT(sbi);
+	int offset = (flag == NAT_BITMAP) ? ckpt->sit_ver_bitmap_bytesize : 0;
+	return &ckpt->sit_nat_version_bitmap + offset;
+}
+
+static inline block_t __start_cp_addr(struct f2fs_sb_info *sbi)
+{
+	block_t start_addr;
+	struct f2fs_checkpoint *ckpt = F2FS_CKPT(sbi);
+	unsigned long long ckpt_version = le64_to_cpu(ckpt->checkpoint_ver);
+
+	start_addr = le64_to_cpu(F2FS_RAW_SUPER(sbi)->start_segment_checkpoint);
+
+	/*
+	 * odd numbered checkpoint shoukd at cp segment 0
+	 * and even segent must be at cp segment 1
+	 */
+	if (!(ckpt_version & 1))
+		start_addr += sbi->blocks_per_seg;
+
+	return start_addr;
+}
+
+static inline block_t __start_sum_addr(struct f2fs_sb_info *sbi)
+{
+	return le32_to_cpu(F2FS_CKPT(sbi)->cp_pack_start_sum);
+}
+
+static inline bool inc_valid_node_count(struct f2fs_sb_info *sbi,
+						struct inode *inode,
+						unsigned int count)
+{
+	block_t	valid_block_count;
+	unsigned int valid_node_count;
+
+	spin_lock(&sbi->stat_lock);
+
+	valid_block_count = sbi->total_valid_block_count + (block_t)count;
+	sbi->alloc_valid_block_count += (block_t)count;
+	valid_node_count = sbi->total_valid_node_count + count;
+
+	if (valid_block_count > sbi->user_block_count) {
+		spin_unlock(&sbi->stat_lock);
+		return false;
+	}
+
+	if (valid_node_count > sbi->total_node_count) {
+		spin_unlock(&sbi->stat_lock);
+		return false;
+	}
+
+	if (inode)
+		inode->i_blocks += count;
+	sbi->total_valid_node_count = valid_node_count;
+	sbi->total_valid_block_count = valid_block_count;
+	spin_unlock(&sbi->stat_lock);
+
+	return true;
+}
+
+static inline void dec_valid_node_count(struct f2fs_sb_info *sbi,
+						struct inode *inode,
+						unsigned int count)
+{
+	spin_lock(&sbi->stat_lock);
+
+	BUG_ON(sbi->total_valid_block_count < count);
+	BUG_ON(sbi->total_valid_node_count < count);
+	BUG_ON(inode->i_blocks < count);
+
+	inode->i_blocks -= count;
+	sbi->total_valid_node_count -= count;
+	sbi->total_valid_block_count -= (block_t)count;
+
+	spin_unlock(&sbi->stat_lock);
+}
+
+static inline unsigned int valid_node_count(struct f2fs_sb_info *sbi)
+{
+	unsigned int ret;
+	spin_lock(&sbi->stat_lock);
+	ret = sbi->total_valid_node_count;
+	spin_unlock(&sbi->stat_lock);
+	return ret;
+}
+
+static inline void inc_valid_inode_count(struct f2fs_sb_info *sbi)
+{
+	spin_lock(&sbi->stat_lock);
+	BUG_ON(sbi->total_valid_inode_count == sbi->total_node_count);
+	sbi->total_valid_inode_count++;
+	spin_unlock(&sbi->stat_lock);
+}
+
+static inline int dec_valid_inode_count(struct f2fs_sb_info *sbi)
+{
+	spin_lock(&sbi->stat_lock);
+	BUG_ON(!sbi->total_valid_inode_count);
+	sbi->total_valid_inode_count--;
+	spin_unlock(&sbi->stat_lock);
+	return 0;
+}
+
+static inline unsigned int valid_inode_count(struct f2fs_sb_info *sbi)
+{
+	unsigned int ret;
+	spin_lock(&sbi->stat_lock);
+	ret = sbi->total_valid_inode_count;
+	spin_unlock(&sbi->stat_lock);
+	return ret;
+}
+
+static inline void f2fs_put_page(struct page *page, int unlock)
+{
+	if (!page || IS_ERR(page))
+		return;
+
+	if (unlock) {
+		BUG_ON(!PageLocked(page));
+		unlock_page(page);
+	}
+	page_cache_release(page);
+}
+
+static inline void f2fs_put_dnode(struct dnode_of_data *dn)
+{
+	if (dn->node_page)
+		f2fs_put_page(dn->node_page, 1);
+	if (dn->inode_page && dn->node_page != dn->inode_page)
+		f2fs_put_page(dn->inode_page, 0);
+	dn->node_page = NULL;
+	dn->inode_page = NULL;
+}
+
+static inline struct kmem_cache *f2fs_kmem_cache_create(const char *name,
+					size_t size, void (*ctor)(void *))
+{
+	return kmem_cache_create(name, size, 0, SLAB_RECLAIM_ACCOUNT, ctor);
+}
+
+#define RAW_IS_INODE(p)	((p)->footer.nid == (p)->footer.ino)
+
+static inline bool IS_INODE(struct page *page)
+{
+	struct f2fs_node *p = (struct f2fs_node *)page_address(page);
+	return RAW_IS_INODE(p);
+}
+
+static inline __le32 *blkaddr_in_node(struct f2fs_node *node)
+{
+	return RAW_IS_INODE(node) ? node->i.i_addr : node->dn.addr;
+}
+
+static inline block_t datablock_addr(struct page *node_page,
+		unsigned int offset)
+{
+	struct f2fs_node *raw_node;
+	__le32 *addr_array;
+	raw_node = (struct f2fs_node *)page_address(node_page);
+	addr_array = blkaddr_in_node(raw_node);
+	return le32_to_cpu(addr_array[offset]);
+}
+
+static inline int f2fs_test_bit(unsigned int nr, char *addr)
+{
+	int mask;
+
+	addr += (nr >> 3);
+	mask = 1 << (7 - (nr & 0x07));
+	return mask & *addr;
+}
+
+static inline int f2fs_set_bit(unsigned int nr, char *addr)
+{
+	int mask;
+	int ret;
+
+	addr += (nr >> 3);
+	mask = 1 << (7 - (nr & 0x07));
+	ret = mask & *addr;
+	*addr |= mask;
+	return ret;
+}
+
+static inline int f2fs_clear_bit(unsigned int nr, char *addr)
+{
+	int mask;
+	int ret;
+
+	addr += (nr >> 3);
+	mask = 1 << (7 - (nr & 0x07));
+	ret = mask & *addr;
+	*addr &= ~mask;
+	return ret;
+}
+
+enum {
+	FI_NEW_INODE,
+	FI_NEED_CP,
+	FI_INC_LINK,
+	FI_ACL_MODE,
+	FI_NO_ALLOC,
+};
+
+static inline void set_inode_flag(struct f2fs_inode_info *fi, int flag)
+{
+	set_bit(flag, &fi->flags);
+}
+
+static inline int is_inode_flag_set(struct f2fs_inode_info *fi, int flag)
+{
+	return test_bit(flag, &fi->flags);
+}
+
+static inline void clear_inode_flag(struct f2fs_inode_info *fi, int flag)
+{
+	clear_bit(flag, &fi->flags);
+}
+
+static inline void set_acl_inode(struct f2fs_inode_info *fi, umode_t mode)
+{
+	fi->i_acl_mode = mode;
+	set_inode_flag(fi, FI_ACL_MODE);
+}
+
+static inline int cond_clear_inode_flag(struct f2fs_inode_info *fi, int flag)
+{
+	if (is_inode_flag_set(fi, FI_ACL_MODE)) {
+		clear_inode_flag(fi, FI_ACL_MODE);
+		return 1;
+	}
+	return 0;
+}
+
+/**
+ * file.c
+ */
+int f2fs_sync_file(struct file *, loff_t, loff_t, int);
+void truncate_data_blocks(struct dnode_of_data *);
+void f2fs_truncate(struct inode *);
+int f2fs_setattr(struct dentry *, struct iattr *);
+int truncate_hole(struct inode *, pgoff_t, pgoff_t);
+long f2fs_ioctl(struct file *, unsigned int, unsigned long);
+
+/**
+ * inode.c
+ */
+void f2fs_set_inode_flags(struct inode *);
+struct inode *f2fs_iget_nowait(struct super_block *, unsigned long);
+struct inode *f2fs_iget(struct super_block *, unsigned long);
+void update_inode(struct inode *, struct page *);
+int f2fs_write_inode(struct inode *, struct writeback_control *);
+void f2fs_evict_inode(struct inode *);
+
+/**
+ * dir.c
+ */
+struct f2fs_dir_entry *f2fs_find_entry(struct inode *, struct qstr *,
+							struct page **);
+struct f2fs_dir_entry *f2fs_parent_dir(struct inode *, struct page **);
+void f2fs_set_link(struct inode *, struct f2fs_dir_entry *,
+				struct page *, struct inode *);
+void init_dent_inode(struct dentry *, struct page *);
+int f2fs_add_link(struct dentry *, struct inode *);
+void f2fs_delete_entry(struct f2fs_dir_entry *, struct page *, struct inode *);
+int f2fs_make_empty(struct inode *, struct inode *);
+bool f2fs_empty_dir(struct inode *);
+
+/**
+ * super.c
+ */
+int f2fs_sync_fs(struct super_block *, int);
+
+/**
+ * hash.c
+ */
+f2fs_hash_t f2fs_dentry_hash(const char *, int);
+
+/**
+ * node.c
+ */
+struct dnode_of_data;
+struct node_info;
+
+int is_checkpointed_node(struct f2fs_sb_info *, nid_t);
+void get_node_info(struct f2fs_sb_info *, nid_t, struct node_info *);
+int get_dnode_of_data(struct dnode_of_data *, pgoff_t, int);
+int truncate_inode_blocks(struct inode *, pgoff_t);
+int remove_inode_page(struct inode *);
+int new_inode_page(struct inode *, struct dentry *);
+struct page *new_node_page(struct dnode_of_data *, unsigned int);
+void ra_node_page(struct f2fs_sb_info *, nid_t);
+struct page *get_node_page(struct f2fs_sb_info *, pgoff_t);
+struct page *get_node_page_ra(struct page *, int);
+void sync_inode_page(struct dnode_of_data *);
+int sync_node_pages(struct f2fs_sb_info *, nid_t, struct writeback_control *);
+bool alloc_nid(struct f2fs_sb_info *, nid_t *);
+void alloc_nid_done(struct f2fs_sb_info *, nid_t);
+void alloc_nid_failed(struct f2fs_sb_info *, nid_t);
+void recover_node_page(struct f2fs_sb_info *, struct page *,
+		struct f2fs_summary *, struct node_info *, block_t);
+int recover_inode_page(struct f2fs_sb_info *, struct page *);
+int restore_node_summary(struct f2fs_sb_info *, unsigned int,
+				struct f2fs_summary_block *);
+void flush_nat_entries(struct f2fs_sb_info *);
+int build_node_manager(struct f2fs_sb_info *);
+void destroy_node_manager(struct f2fs_sb_info *);
+int create_node_manager_caches(void);
+void destroy_node_manager_caches(void);
+
+/**
+ * segment.c
+ */
+void f2fs_balance_fs(struct f2fs_sb_info *);
+void invalidate_blocks(struct f2fs_sb_info *, block_t);
+void locate_dirty_segment(struct f2fs_sb_info *, unsigned int);
+void clear_prefree_segments(struct f2fs_sb_info *);
+int npages_for_summary_flush(struct f2fs_sb_info *);
+void allocate_new_segments(struct f2fs_sb_info *);
+struct page *get_sum_page(struct f2fs_sb_info *, unsigned int);
+struct bio *f2fs_bio_alloc(struct block_device *, sector_t, int, gfp_t);
+void f2fs_submit_bio(struct f2fs_sb_info *, enum page_type, bool sync);
+int write_meta_page(struct f2fs_sb_info *, struct page *,
+					struct writeback_control *);
+void write_node_page(struct f2fs_sb_info *, struct page *, unsigned int,
+					block_t, block_t *);
+void write_data_page(struct inode *, struct page *, struct dnode_of_data*,
+					block_t, block_t *);
+void rewrite_data_page(struct f2fs_sb_info *, struct page *, block_t);
+void recover_data_page(struct f2fs_sb_info *, struct page *,
+				struct f2fs_summary *, block_t, block_t);
+void rewrite_node_page(struct f2fs_sb_info *, struct page *,
+				struct f2fs_summary *, block_t, block_t);
+void write_data_summaries(struct f2fs_sb_info *, block_t);
+void write_node_summaries(struct f2fs_sb_info *, block_t);
+int lookup_journal_in_cursum(struct f2fs_summary_block *,
+					int, unsigned int, int);
+void flush_sit_entries(struct f2fs_sb_info *);
+int build_segment_manager(struct f2fs_sb_info *);
+void reset_victim_segmap(struct f2fs_sb_info *);
+void destroy_segment_manager(struct f2fs_sb_info *);
+
+/**
+ * checkpoint.c
+ */
+struct page *grab_meta_page(struct f2fs_sb_info *, pgoff_t);
+struct page *get_meta_page(struct f2fs_sb_info *, pgoff_t);
+long sync_meta_pages(struct f2fs_sb_info *, enum page_type, long);
+int check_orphan_space(struct f2fs_sb_info *);
+void add_orphan_inode(struct f2fs_sb_info *, nid_t);
+void remove_orphan_inode(struct f2fs_sb_info *, nid_t);
+int recover_orphan_inodes(struct f2fs_sb_info *);
+int get_valid_checkpoint(struct f2fs_sb_info *);
+void set_dirty_dir_page(struct inode *, struct page *);
+void remove_dirty_dir_inode(struct inode *);
+void sync_dirty_dir_inodes(struct f2fs_sb_info *);
+void block_operations(struct f2fs_sb_info *);
+void write_checkpoint(struct f2fs_sb_info *, bool, bool);
+void init_orphan_info(struct f2fs_sb_info *);
+int create_checkpoint_caches(void);
+void destroy_checkpoint_caches(void);
+
+/**
+ * data.c
+ */
+int reserve_new_block(struct dnode_of_data *);
+void update_extent_cache(block_t, struct dnode_of_data *);
+struct page *find_data_page(struct inode *, pgoff_t);
+struct page *get_lock_data_page(struct inode *, pgoff_t);
+struct page *get_new_data_page(struct inode *, pgoff_t, bool);
+int f2fs_readpage(struct f2fs_sb_info *, struct page *, block_t, int);
+int do_write_data_page(struct page *);
+
+/**
+ * gc.c
+ */
+int start_gc_thread(struct f2fs_sb_info *);
+void stop_gc_thread(struct f2fs_sb_info *);
+block_t start_bidx_of_node(unsigned int);
+int f2fs_gc(struct f2fs_sb_info *, int);
+#ifdef CONFIG_F2FS_STAT_FS
+void f2fs_update_stat(struct f2fs_sb_info *);
+void f2fs_update_gc_metric(struct f2fs_sb_info *);
+int f2fs_stat_init(struct f2fs_sb_info *);
+void f2fs_stat_exit(struct f2fs_sb_info *);
+#endif
+int build_gc_manager(struct f2fs_sb_info *);
+void destroy_gc_manager(struct f2fs_sb_info *);
+int create_gc_caches(void);
+void destroy_gc_caches(void);
+
+/**
+ * recovery.c
+ */
+void recover_fsync_data(struct f2fs_sb_info *);
+bool space_for_roll_forward(struct f2fs_sb_info *);
+
+extern const struct file_operations f2fs_dir_operations;
+extern const struct file_operations f2fs_file_operations;
+extern const struct inode_operations f2fs_file_inode_operations;
+extern const struct address_space_operations f2fs_dblock_aops;
+extern const struct address_space_operations f2fs_node_aops;
+extern const struct address_space_operations f2fs_meta_aops;
+extern const struct inode_operations f2fs_dir_inode_operations;
+extern const struct inode_operations f2fs_symlink_inode_operations;
+extern const struct inode_operations f2fs_special_inode_operations;
+#endif
diff --git a/fs/f2fs/node.h b/fs/f2fs/node.h
new file mode 100644
index 0000000..99ac689
--- /dev/null
+++ b/fs/f2fs/node.h
@@ -0,0 +1,330 @@
+/**
+ * fs/f2fs/node.h
+ *
+ * Copyright (c) 2012 Samsung Electronics Co., Ltd.
+ *             http://www.samsung.com/
+ *
+ * This program is free software; you can redistribute it and/or modify
+ * it under the terms of the GNU General Public License version 2 as
+ * published by the Free Software Foundation.
+ */
+#define	START_NID(nid) ((nid / NAT_ENTRY_PER_BLOCK) * NAT_ENTRY_PER_BLOCK)
+#define	NAT_BLOCK_OFFSET(start_nid) (start_nid / NAT_ENTRY_PER_BLOCK)
+
+#define FREE_NID_PAGES 4
+#define MAX_FREE_NIDS (NAT_ENTRY_PER_BLOCK * FREE_NID_PAGES)
+
+#define MAX_RA_NODE		128	/* Max. readahead size for node */
+#define NM_WOUT_THRESHOLD	(64 * NAT_ENTRY_PER_BLOCK)
+#define NATVEC_SIZE	64
+
+/**
+ * For node information
+ */
+struct node_info {
+	nid_t nid;	/* node id */
+	nid_t ino;	/* inode number of the node's owner */
+	block_t	blk_addr;	/* block address of the node */
+	unsigned char version;	/* version of the node */
+};
+
+static inline unsigned char inc_node_version(unsigned char version)
+{
+	return ++version;
+}
+
+struct nat_entry {
+	struct list_head list;	/* for clean or dirty nat list */
+	bool checkpointed;
+	struct node_info ni;
+};
+
+#define nat_get_nid(nat)		(nat->ni.nid)
+#define nat_set_nid(nat, n)		(nat->ni.nid = n)
+#define nat_get_blkaddr(nat)		(nat->ni.blk_addr)
+#define nat_set_blkaddr(nat, b)		(nat->ni.blk_addr = b)
+#define nat_get_ino(nat)		(nat->ni.ino)
+#define nat_set_ino(nat, i)		(nat->ni.ino = i)
+#define nat_get_version(nat)		(nat->ni.version)
+#define nat_set_version(nat, v)		(nat->ni.version = v)
+#define __set_nat_cache_dirty(nm_i, ne)				\
+	list_move_tail(&ne->list, &nm_i->dirty_nat_entries);
+#define __clear_nat_cache_dirty(nm_i, ne)				\
+	list_move_tail(&ne->list, &nm_i->nat_entries);
+
+static inline void node_info_from_raw_nat(struct node_info *ni,
+						struct f2fs_nat_entry *raw_ne)
+{
+	ni->ino = le32_to_cpu(raw_ne->ino);
+	ni->blk_addr = le32_to_cpu(raw_ne->block_addr);
+	ni->version = raw_ne->version;
+}
+
+/**
+ * For free nid mangement
+ */
+enum nid_state {
+	NID_NEW,
+	NID_ALLOC
+};
+
+struct free_nid {
+	nid_t nid;
+	int state;
+	struct list_head list;
+};
+
+static inline int next_free_nid(struct f2fs_sb_info *sbi, nid_t *nid)
+{
+	struct f2fs_nm_info *nm_i = NM_I(sbi);
+	struct free_nid *fnid;
+
+	if (nm_i->fcnt <= 0)
+		return -1;
+	spin_lock(&nm_i->free_nid_list_lock);
+	fnid = list_entry(nm_i->free_nid_list.next, struct free_nid, list);
+	*nid = fnid->nid;
+	spin_unlock(&nm_i->free_nid_list_lock);
+	return 0;
+}
+
+/**
+ * inline functions
+ */
+static inline void get_nat_bitmap(struct f2fs_sb_info *sbi, void *addr)
+{
+	struct f2fs_nm_info *nm_i = NM_I(sbi);
+	memcpy(addr, nm_i->nat_bitmap, nm_i->bitmap_size);
+}
+
+static inline pgoff_t current_nat_addr(struct f2fs_sb_info *sbi, nid_t start)
+{
+	struct f2fs_nm_info *nm_i = NM_I(sbi);
+	pgoff_t block_off;
+	pgoff_t block_addr;
+	int seg_off;
+
+	block_off = NAT_BLOCK_OFFSET(start);
+	seg_off = block_off >> sbi->log_blocks_per_seg;
+
+	block_addr = (pgoff_t)(nm_i->nat_blkaddr +
+		(seg_off << sbi->log_blocks_per_seg << 1) +
+		(block_off & ((1 << sbi->log_blocks_per_seg) - 1)));
+
+	if (f2fs_test_bit(block_off, nm_i->nat_bitmap))
+		block_addr += sbi->blocks_per_seg;
+
+	return block_addr;
+}
+
+static inline pgoff_t next_nat_addr(struct f2fs_sb_info *sbi,
+						pgoff_t block_addr)
+{
+	struct f2fs_nm_info *nm_i = NM_I(sbi);
+
+	block_addr -= nm_i->nat_blkaddr;
+	if ((block_addr >> sbi->log_blocks_per_seg) % 2)
+		block_addr -= sbi->blocks_per_seg;
+	else
+		block_addr += sbi->blocks_per_seg;
+
+	return block_addr + nm_i->nat_blkaddr;
+}
+
+static inline void set_to_next_nat(struct f2fs_nm_info *nm_i, nid_t start_nid)
+{
+	unsigned int block_off = NAT_BLOCK_OFFSET(start_nid);
+
+	if (f2fs_test_bit(block_off, nm_i->nat_bitmap))
+		f2fs_clear_bit(block_off, nm_i->nat_bitmap);
+	else
+		f2fs_set_bit(block_off, nm_i->nat_bitmap);
+}
+
+static inline void fill_node_footer(struct page *page, nid_t nid,
+				nid_t ino, unsigned int ofs, bool reset)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	if (reset)
+		memset(rn, 0, sizeof(*rn));
+	rn->footer.nid = cpu_to_le32(nid);
+	rn->footer.ino = cpu_to_le32(ino);
+	rn->footer.flag = cpu_to_le32(ofs << OFFSET_BIT_SHIFT);
+}
+
+static inline void copy_node_footer(struct page *dst, struct page *src)
+{
+	void *src_addr = page_address(src);
+	void *dst_addr = page_address(dst);
+	struct f2fs_node *src_rn = (struct f2fs_node *)src_addr;
+	struct f2fs_node *dst_rn = (struct f2fs_node *)dst_addr;
+	memcpy(&dst_rn->footer, &src_rn->footer, sizeof(struct node_footer));
+}
+
+static inline void fill_node_footer_blkaddr(struct page *page, block_t blkaddr)
+{
+	struct f2fs_sb_info *sbi = F2FS_SB(page->mapping->host->i_sb);
+	struct f2fs_checkpoint *ckpt = F2FS_CKPT(sbi);
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	rn->footer.cp_ver = ckpt->checkpoint_ver;
+	rn->footer.next_blkaddr = blkaddr;
+}
+
+static inline nid_t ino_of_node(struct page *node_page)
+{
+	void *kaddr = page_address(node_page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	return le32_to_cpu(rn->footer.ino);
+}
+
+static inline nid_t nid_of_node(struct page *node_page)
+{
+	void *kaddr = page_address(node_page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	return le32_to_cpu(rn->footer.nid);
+}
+
+static inline unsigned int ofs_of_node(struct page *node_page)
+{
+	void *kaddr = page_address(node_page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned flag = le32_to_cpu(rn->footer.flag);
+	return flag >> OFFSET_BIT_SHIFT;
+}
+
+static inline unsigned long long cpver_of_node(struct page *node_page)
+{
+	void *kaddr = page_address(node_page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	return le64_to_cpu(rn->footer.cp_ver);
+}
+
+static inline block_t next_blkaddr_of_node(struct page *node_page)
+{
+	void *kaddr = page_address(node_page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	return le32_to_cpu(rn->footer.next_blkaddr);
+}
+
+static inline bool IS_DNODE(struct page *node_page)
+{
+	unsigned int ofs = ofs_of_node(node_page);
+	if (ofs == 3 || ofs == 4 + NIDS_PER_BLOCK ||
+			ofs == 5 + 2 * NIDS_PER_BLOCK)
+		return false;
+	if (ofs >= 6 + 2 * NIDS_PER_BLOCK) {
+		ofs -= 6 + 2 * NIDS_PER_BLOCK;
+		if ((long int)ofs % (NIDS_PER_BLOCK + 1))
+			return false;
+	}
+	return true;
+}
+
+static inline void set_nid(struct page *p, int off, nid_t nid, bool i)
+{
+	struct f2fs_node *rn = (struct f2fs_node *)page_address(p);
+
+	wait_on_page_writeback(p);
+
+	if (i)
+		rn->i.i_nid[off - NODE_DIR1_BLOCK] = cpu_to_le32(nid);
+	else
+		rn->in.nid[off] = cpu_to_le32(nid);
+	set_page_dirty(p);
+}
+
+static inline nid_t get_nid(struct page *p, int off, bool i)
+{
+	struct f2fs_node *rn = (struct f2fs_node *)page_address(p);
+	if (i)
+		return le32_to_cpu(rn->i.i_nid[off - NODE_DIR1_BLOCK]);
+	return le32_to_cpu(rn->in.nid[off]);
+}
+
+/**
+ * Coldness identification:
+ *  - Mark cold files in f2fs_inode_info
+ *  - Mark cold node blocks in their node footer
+ *  - Mark cold data pages in page cache
+ */
+static inline int is_cold_file(struct inode *inode)
+{
+	return F2FS_I(inode)->i_advise & FADVISE_COLD_BIT;
+}
+
+static inline int is_cold_data(struct page *page)
+{
+	return PageChecked(page);
+}
+
+static inline void set_cold_data(struct page *page)
+{
+	SetPageChecked(page);
+}
+
+static inline void clear_cold_data(struct page *page)
+{
+	ClearPageChecked(page);
+}
+
+static inline int is_cold_node(struct page *page)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+	return flag & (0x1 << COLD_BIT_SHIFT);
+}
+
+static inline unsigned char is_fsync_dnode(struct page *page)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+	return flag & (0x1 << FSYNC_BIT_SHIFT);
+}
+
+static inline unsigned char is_dent_dnode(struct page *page)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+	return flag & (0x1 << DENT_BIT_SHIFT);
+}
+
+static inline void set_cold_node(struct inode *inode, struct page *page)
+{
+	struct f2fs_node *rn = (struct f2fs_node *)page_address(page);
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+
+	if (S_ISDIR(inode->i_mode))
+		flag &= ~(0x1 << COLD_BIT_SHIFT);
+	else
+		flag |= (0x1 << COLD_BIT_SHIFT);
+	rn->footer.flag = cpu_to_le32(flag);
+}
+
+static inline void set_fsync_mark(struct page *page, int mark)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+	if (mark)
+		flag |= (0x1 << FSYNC_BIT_SHIFT);
+	else
+		flag &= ~(0x1 << FSYNC_BIT_SHIFT);
+	rn->footer.flag = cpu_to_le32(flag);
+}
+
+static inline void set_dentry_mark(struct page *page, int mark)
+{
+	void *kaddr = page_address(page);
+	struct f2fs_node *rn = (struct f2fs_node *)kaddr;
+	unsigned int flag = le32_to_cpu(rn->footer.flag);
+	if (mark)
+		flag |= (0x1 << DENT_BIT_SHIFT);
+	else
+		flag &= ~(0x1 << DENT_BIT_SHIFT);
+	rn->footer.flag = cpu_to_le32(flag);
+}
diff --git a/fs/f2fs/segment.h b/fs/f2fs/segment.h
new file mode 100644
index 0000000..cd6268e
--- /dev/null
+++ b/fs/f2fs/segment.h
@@ -0,0 +1,594 @@
+/**
+ * fs/f2fs/segment.h
+ *
+ * Copyright (c) 2012 Samsung Electronics Co., Ltd.
+ *             http://www.samsung.com/
+ *
+ * This program is free software; you can redistribute it and/or modify
+ * it under the terms of the GNU General Public License version 2 as
+ * published by the Free Software Foundation.
+ */
+/* constant macro */
+#define NULL_SEGNO			((unsigned int)(~0))
+#define SUM_TYPE_NODE			(1)
+#define SUM_TYPE_DATA			(0)
+
+/* V: Logical segment # in volume, R: Relative segment # in main area */
+#define GET_L2R_SEGNO(free_i, segno)	(segno - free_i->start_segno)
+#define GET_R2L_SEGNO(free_i, segno)	(segno + free_i->start_segno)
+
+#define IS_DATASEG(t)							\
+	((t == CURSEG_HOT_DATA) || (t == CURSEG_COLD_DATA) ||		\
+	(t == CURSEG_WARM_DATA))
+
+#define IS_NODESEG(t)							\
+	((t == CURSEG_HOT_NODE) || (t == CURSEG_COLD_NODE) ||		\
+	(t == CURSEG_WARM_NODE))
+
+#define IS_CURSEG(sbi, segno)						\
+	((segno == CURSEG_I(sbi, CURSEG_HOT_DATA)->segno) ||	\
+	 (segno == CURSEG_I(sbi, CURSEG_WARM_DATA)->segno) ||	\
+	 (segno == CURSEG_I(sbi, CURSEG_COLD_DATA)->segno) ||	\
+	 (segno == CURSEG_I(sbi, CURSEG_HOT_NODE)->segno) ||	\
+	 (segno == CURSEG_I(sbi, CURSEG_WARM_NODE)->segno) ||	\
+	 (segno == CURSEG_I(sbi, CURSEG_COLD_NODE)->segno))
+
+#define IS_CURSEC(sbi, secno)						\
+	((secno == CURSEG_I(sbi, CURSEG_HOT_DATA)->segno /		\
+	  sbi->segs_per_sec) ||	\
+	 (secno == CURSEG_I(sbi, CURSEG_WARM_DATA)->segno /		\
+	  sbi->segs_per_sec) ||	\
+	 (secno == CURSEG_I(sbi, CURSEG_COLD_DATA)->segno /		\
+	  sbi->segs_per_sec) ||	\
+	 (secno == CURSEG_I(sbi, CURSEG_HOT_NODE)->segno /		\
+	  sbi->segs_per_sec) ||	\
+	 (secno == CURSEG_I(sbi, CURSEG_WARM_NODE)->segno /		\
+	  sbi->segs_per_sec) ||	\
+	 (secno == CURSEG_I(sbi, CURSEG_COLD_NODE)->segno /		\
+	  sbi->segs_per_sec))	\
+
+#define START_BLOCK(sbi, segno)						\
+	(SM_I(sbi)->seg0_blkaddr +					\
+	 (GET_R2L_SEGNO(FREE_I(sbi), segno) << sbi->log_blocks_per_seg))
+#define NEXT_FREE_BLKADDR(sbi, curseg)					\
+	(START_BLOCK(sbi, curseg->segno) + curseg->next_blkoff)
+
+#define MAIN_BASE_BLOCK(sbi)	(SM_I(sbi)->main_blkaddr)
+
+#define GET_SEGOFF_FROM_SEG0(sbi, blk_addr)				\
+	((blk_addr) - SM_I(sbi)->seg0_blkaddr)
+#define GET_SEGNO_FROM_SEG0(sbi, blk_addr)				\
+	(GET_SEGOFF_FROM_SEG0(sbi, blk_addr) >> sbi->log_blocks_per_seg)
+#define GET_SEGNO(sbi, blk_addr)					\
+	(((blk_addr == NULL_ADDR) || (blk_addr == NEW_ADDR)) ?		\
+	NULL_SEGNO : GET_L2R_SEGNO(FREE_I(sbi),			\
+		GET_SEGNO_FROM_SEG0(sbi, blk_addr)))
+#define GET_SECNO(sbi, segno)					\
+	((segno) / sbi->segs_per_sec)
+#define GET_ZONENO_FROM_SEGNO(sbi, segno)				\
+	((segno / sbi->segs_per_sec) / sbi->secs_per_zone)
+
+#define GET_SUM_BLOCK(sbi, segno)				\
+	((sbi->sm_info->ssa_blkaddr) + segno)
+
+#define GET_SUM_TYPE(footer) ((footer)->entry_type)
+#define SET_SUM_TYPE(footer, type) ((footer)->entry_type = type)
+
+#define SIT_ENTRY_OFFSET(sit_i, segno)					\
+	(segno % sit_i->sents_per_block)
+#define SIT_BLOCK_OFFSET(sit_i, segno)					\
+	(segno / SIT_ENTRY_PER_BLOCK)
+#define	START_SEGNO(sit_i, segno)		\
+	(SIT_BLOCK_OFFSET(sit_i, segno) * SIT_ENTRY_PER_BLOCK)
+#define f2fs_bitmap_size(nr)			\
+	(BITS_TO_LONGS(nr) * sizeof(unsigned long))
+#define TOTAL_SEGS(sbi)	(SM_I(sbi)->main_segment_count)
+
+enum {
+	LFS = 0,
+	SSR
+};
+
+enum {
+	ALLOC_RIGHT = 0,
+	ALLOC_LEFT
+};
+
+#define SET_SSR_TYPE(type)	(((type) + 1) << 16)
+#define GET_SSR_TYPE(type)	(((type) >> 16) - 1)
+#define IS_SSR_TYPE(type)	((type) >= (0x1 << 16))
+#define IS_NEXT_SEG(sbi, curseg, type)					\
+	(DIRTY_I(sbi)->v_ops->get_victim(sbi, &(curseg)->next_segno,	\
+				     BG_GC, SET_SSR_TYPE(type)))
+/**
+ * The MSB 6 bits of f2fs_sit_entry->vblocks has segment type,
+ * and LSB 10 bits has valid blocks.
+ */
+#define VBLOCKS_MASK		((1 << 10) - 1)
+
+#define GET_SIT_VBLOCKS(raw_sit)	\
+	(le16_to_cpu((raw_sit)->vblocks) & VBLOCKS_MASK)
+#define GET_SIT_TYPE(raw_sit)		\
+	((le16_to_cpu((raw_sit)->vblocks) & ~VBLOCKS_MASK) >> 10)
+
+struct bio_private {
+	struct f2fs_sb_info *sbi;
+	bool is_sync;
+	void *wait;
+};
+
+enum {
+	GC_CB = 0,
+	GC_GREEDY
+};
+
+struct victim_sel_policy {
+	int alloc_mode;
+	int gc_mode;
+	int type;
+	unsigned long *dirty_segmap;
+	unsigned int offset;
+	unsigned int ofs_unit;
+	unsigned int min_cost;
+	unsigned int min_segno;
+};
+
+struct seg_entry {
+	unsigned short valid_blocks;
+	unsigned char *cur_valid_map;
+	unsigned short ckpt_valid_blocks;
+	unsigned char *ckpt_valid_map;
+	unsigned char type;
+	unsigned long long mtime;
+};
+
+struct sec_entry {
+	unsigned int valid_blocks;
+};
+
+struct segment_allocation {
+	void (*allocate_segment)(struct f2fs_sb_info *, int, bool);
+};
+
+struct sit_info {
+	const struct segment_allocation *s_ops;
+
+	block_t sit_base_addr;
+	block_t sit_blocks;
+	block_t written_valid_blocks;		/* total number of valid blocks
+						   in main area */
+	char *sit_bitmap;			/* SIT bitmap pointer */
+	unsigned int bitmap_size;
+
+	unsigned int dirty_sentries;		/* # of dirty sentries */
+	unsigned long *dirty_sentries_bitmap;	/* bitmap for dirty sentries */
+	unsigned int sents_per_block;		/* number of SIT entries
+						   per SIT block */
+	struct mutex sentry_lock;		/* to protect SIT entries */
+	struct seg_entry *sentries;
+	struct sec_entry *sec_entries;
+
+	unsigned long long elapsed_time;
+	unsigned long long mounted_time;
+	unsigned long long min_mtime;
+	unsigned long long max_mtime;
+};
+
+struct free_segmap_info {
+	unsigned int start_segno;
+	unsigned int free_segments;
+	unsigned int free_sections;
+	rwlock_t segmap_lock;		/* free segmap lock */
+	unsigned long *free_segmap;
+	unsigned long *free_secmap;
+};
+
+/* Notice: The order of dirty type is same with CURSEG_XXX in f2fs.h */
+enum dirty_type {
+	DIRTY_HOT_DATA,		/* a few valid blocks in a data segment */
+	DIRTY_WARM_DATA,
+	DIRTY_COLD_DATA,
+	DIRTY_HOT_NODE,		/* a few valid blocks in a node segment */
+	DIRTY_WARM_NODE,
+	DIRTY_COLD_NODE,
+	DIRTY,
+	PRE,			/* no valid blocks in a segment */
+	NR_DIRTY_TYPE
+};
+
+enum {
+	BG_GC,
+	FG_GC
+};
+
+struct dirty_seglist_info {
+	const struct victim_selection *v_ops;
+	struct mutex seglist_lock;
+	unsigned long *dirty_segmap[NR_DIRTY_TYPE];
+	int nr_dirty[NR_DIRTY_TYPE];
+	unsigned long *victim_segmap[2];	/* BG_GC, FG_GC */
+};
+
+struct victim_selection {
+	int (*get_victim)(struct f2fs_sb_info *, unsigned int *, int, int);
+};
+
+struct curseg_info {
+	struct mutex curseg_mutex;
+	struct f2fs_summary_block *sum_blk;
+	unsigned char alloc_type;
+	unsigned int segno;
+	unsigned short next_blkoff;
+	unsigned int zone;
+	unsigned int next_segno;
+};
+
+/**
+ * inline functions
+ */
+static inline struct curseg_info *CURSEG_I(struct f2fs_sb_info *sbi, int type)
+{
+	return (struct curseg_info *)(SM_I(sbi)->curseg_array + type);
+}
+
+static inline struct seg_entry *get_seg_entry(struct f2fs_sb_info *sbi,
+						unsigned int segno)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	return &sit_i->sentries[segno];
+}
+
+static inline struct sec_entry *get_sec_entry(struct f2fs_sb_info *sbi,
+						unsigned int segno)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	return &sit_i->sec_entries[GET_SECNO(sbi, segno)];
+}
+
+static inline unsigned int get_valid_blocks(struct f2fs_sb_info *sbi,
+				unsigned int segno, int section)
+{
+	if (section > 1)
+		return get_sec_entry(sbi, segno)->valid_blocks;
+	else
+		return get_seg_entry(sbi, segno)->valid_blocks;
+}
+
+static inline void seg_info_from_raw_sit(struct seg_entry *se,
+					struct f2fs_sit_entry *rs)
+{
+	se->valid_blocks = GET_SIT_VBLOCKS(rs);
+	se->ckpt_valid_blocks = GET_SIT_VBLOCKS(rs);
+	memcpy(se->cur_valid_map, rs->valid_map, SIT_VBLOCK_MAP_SIZE);
+	memcpy(se->ckpt_valid_map, rs->valid_map, SIT_VBLOCK_MAP_SIZE);
+	se->type = GET_SIT_TYPE(rs);
+	se->mtime = le64_to_cpu(rs->mtime);
+}
+
+static inline void seg_info_to_raw_sit(struct seg_entry *se,
+					struct f2fs_sit_entry *rs)
+{
+	unsigned short raw_vblocks = (se->type << 10) | se->valid_blocks;
+	rs->vblocks = cpu_to_le16(raw_vblocks);
+	memcpy(rs->valid_map, se->cur_valid_map, SIT_VBLOCK_MAP_SIZE);
+	memcpy(se->ckpt_valid_map, rs->valid_map, SIT_VBLOCK_MAP_SIZE);
+	se->ckpt_valid_blocks = se->valid_blocks;
+	rs->mtime = cpu_to_le64(se->mtime);
+}
+
+static inline unsigned int find_next_inuse(struct free_segmap_info *free_i,
+		unsigned int max, unsigned int segno)
+{
+	unsigned int ret;
+	read_lock(&free_i->segmap_lock);
+	ret = find_next_bit(free_i->free_segmap, max, segno);
+	read_unlock(&free_i->segmap_lock);
+	return ret;
+}
+
+static inline void __set_free(struct f2fs_sb_info *sbi, unsigned int segno)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int secno = segno / sbi->segs_per_sec;
+	unsigned int start_segno = secno * sbi->segs_per_sec;
+	unsigned int next;
+
+	write_lock(&free_i->segmap_lock);
+	clear_bit(segno, free_i->free_segmap);
+	free_i->free_segments++;
+
+	next = find_next_bit(free_i->free_segmap, TOTAL_SEGS(sbi), start_segno);
+	if (next >= start_segno + sbi->segs_per_sec) {
+		clear_bit(secno, free_i->free_secmap);
+		free_i->free_sections++;
+	}
+	write_unlock(&free_i->segmap_lock);
+}
+
+static inline void __set_inuse(struct f2fs_sb_info *sbi,
+		unsigned int segno)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int secno = segno / sbi->segs_per_sec;
+	set_bit(segno, free_i->free_segmap);
+	free_i->free_segments--;
+	if (!test_and_set_bit(secno, free_i->free_secmap))
+		free_i->free_sections--;
+}
+
+static inline void __set_test_and_free(struct f2fs_sb_info *sbi,
+		unsigned int segno)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int secno = segno / sbi->segs_per_sec;
+	unsigned int start_segno = secno * sbi->segs_per_sec;
+	unsigned int next;
+
+	write_lock(&free_i->segmap_lock);
+	if (test_and_clear_bit(segno, free_i->free_segmap)) {
+		free_i->free_segments++;
+
+		next = find_next_bit(free_i->free_segmap, TOTAL_SEGS(sbi),
+								start_segno);
+		if (next >= start_segno + sbi->segs_per_sec) {
+			if (test_and_clear_bit(secno, free_i->free_secmap))
+				free_i->free_sections++;
+		}
+	}
+	write_unlock(&free_i->segmap_lock);
+}
+
+static inline void __set_test_and_inuse(struct f2fs_sb_info *sbi,
+		unsigned int segno)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int secno = segno / sbi->segs_per_sec;
+	write_lock(&free_i->segmap_lock);
+	if (!test_and_set_bit(segno, free_i->free_segmap)) {
+		free_i->free_segments--;
+		if (!test_and_set_bit(secno, free_i->free_secmap))
+			free_i->free_sections--;
+	}
+	write_unlock(&free_i->segmap_lock);
+}
+
+static inline void get_sit_bitmap(struct f2fs_sb_info *sbi,
+		void *dst_addr)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	memcpy(dst_addr, sit_i->sit_bitmap, sit_i->bitmap_size);
+}
+
+static inline block_t written_block_count(struct f2fs_sb_info *sbi)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	block_t vblocks;
+
+	mutex_lock(&sit_i->sentry_lock);
+	vblocks = sit_i->written_valid_blocks;
+	mutex_unlock(&sit_i->sentry_lock);
+
+	return vblocks;
+}
+
+static inline unsigned int free_segments(struct f2fs_sb_info *sbi)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int free_segs;
+
+	read_lock(&free_i->segmap_lock);
+	free_segs = free_i->free_segments;
+	read_unlock(&free_i->segmap_lock);
+
+	return free_segs;
+}
+
+static inline int reserved_segments(struct f2fs_sb_info *sbi)
+{
+	struct f2fs_gc_info *gc_i = sbi->gc_info;
+	return gc_i->rsvd_segment_count;
+}
+
+static inline unsigned int free_sections(struct f2fs_sb_info *sbi)
+{
+	struct free_segmap_info *free_i = FREE_I(sbi);
+	unsigned int free_secs;
+
+	read_lock(&free_i->segmap_lock);
+	free_secs = free_i->free_sections;
+	read_unlock(&free_i->segmap_lock);
+
+	return free_secs;
+}
+
+static inline unsigned int prefree_segments(struct f2fs_sb_info *sbi)
+{
+	return DIRTY_I(sbi)->nr_dirty[PRE];
+}
+
+static inline unsigned int dirty_segments(struct f2fs_sb_info *sbi)
+{
+	return DIRTY_I(sbi)->nr_dirty[DIRTY_HOT_DATA] +
+		DIRTY_I(sbi)->nr_dirty[DIRTY_WARM_DATA] +
+		DIRTY_I(sbi)->nr_dirty[DIRTY_COLD_DATA] +
+		DIRTY_I(sbi)->nr_dirty[DIRTY_HOT_NODE] +
+		DIRTY_I(sbi)->nr_dirty[DIRTY_WARM_NODE] +
+		DIRTY_I(sbi)->nr_dirty[DIRTY_COLD_NODE];
+}
+
+static inline int overprovision_segments(struct f2fs_sb_info *sbi)
+{
+	struct f2fs_gc_info *gc_i = sbi->gc_info;
+	return gc_i->overp_segment_count;
+}
+
+static inline int overprovision_sections(struct f2fs_sb_info *sbi)
+{
+	struct f2fs_gc_info *gc_i = sbi->gc_info;
+	return ((unsigned int) gc_i->overp_segment_count) / sbi->segs_per_sec;
+}
+
+static inline int reserved_sections(struct f2fs_sb_info *sbi)
+{
+	struct f2fs_gc_info *gc_i = sbi->gc_info;
+	return ((unsigned int) gc_i->rsvd_segment_count) / sbi->segs_per_sec;
+}
+
+static inline bool need_SSR(struct f2fs_sb_info *sbi)
+{
+	return (free_sections(sbi) < overprovision_sections(sbi));
+}
+
+static inline bool has_not_enough_free_secs(struct f2fs_sb_info *sbi)
+{
+	return free_sections(sbi) <= reserved_sections(sbi);
+}
+
+static inline int utilization(struct f2fs_sb_info *sbi)
+{
+	return (long int)valid_user_blocks(sbi) * 100 /
+			(long int)sbi->user_block_count;
+}
+
+/* Disable In-Place-Update by default */
+#define MIN_IPU_UTIL		100
+static inline bool need_inplace_update(struct inode *inode)
+{
+	struct f2fs_sb_info *sbi = F2FS_SB(inode->i_sb);
+	if (S_ISDIR(inode->i_mode))
+		return false;
+	if (need_SSR(sbi) && utilization(sbi) > MIN_IPU_UTIL)
+		return true;
+	return false;
+}
+
+static inline unsigned int curseg_segno(struct f2fs_sb_info *sbi,
+		int type)
+{
+	struct curseg_info *curseg = CURSEG_I(sbi, type);
+	return curseg->segno;
+}
+
+static inline unsigned char curseg_alloc_type(struct f2fs_sb_info *sbi,
+		int type)
+{
+	struct curseg_info *curseg = CURSEG_I(sbi, type);
+	return curseg->alloc_type;
+}
+
+static inline unsigned short curseg_blkoff(struct f2fs_sb_info *sbi, int type)
+{
+	struct curseg_info *curseg = CURSEG_I(sbi, type);
+	return curseg->next_blkoff;
+}
+
+static inline void check_seg_range(struct f2fs_sb_info *sbi, unsigned int segno)
+{
+	unsigned int end_segno = SM_I(sbi)->segment_count - 1;
+	BUG_ON(segno > end_segno);
+}
+
+/*
+ * This function is used for only debugging.
+ * NOTE: In future, we have to remove this function.
+ */
+static inline void verify_block_addr(struct f2fs_sb_info *sbi, block_t blk_addr)
+{
+	struct f2fs_sm_info *sm_info = SM_I(sbi);
+	block_t total_blks = sm_info->segment_count << sbi->log_blocks_per_seg;
+	block_t start_addr = sm_info->seg0_blkaddr;
+	block_t end_addr = start_addr + total_blks - 1;
+	BUG_ON(blk_addr < start_addr);
+	BUG_ON(blk_addr > end_addr);
+}
+
+/**
+ * Summary block is always treated as invalid block
+ */
+static inline void check_block_count(struct f2fs_sb_info *sbi,
+		int segno, struct f2fs_sit_entry *raw_sit)
+{
+	struct f2fs_sm_info *sm_info = SM_I(sbi);
+	unsigned int end_segno = sm_info->segment_count - 1;
+	int valid_blocks = 0;
+	int i;
+
+	/* check segment usage */
+	BUG_ON(GET_SIT_VBLOCKS(raw_sit) > sbi->blocks_per_seg);
+
+	/* check boundary of a given segment number */
+	BUG_ON(segno > end_segno);
+
+	/* check bitmap with valid block count */
+	for (i = 0; i < sbi->blocks_per_seg; i++)
+		if (f2fs_test_bit(i, raw_sit->valid_map))
+			valid_blocks++;
+	BUG_ON(GET_SIT_VBLOCKS(raw_sit) != valid_blocks);
+}
+
+static inline pgoff_t current_sit_addr(struct f2fs_sb_info *sbi,
+						unsigned int start)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	unsigned int offset = SIT_BLOCK_OFFSET(sit_i, start);
+	block_t blk_addr = sit_i->sit_base_addr + offset;
+
+	check_seg_range(sbi, start);
+
+	/* calculate sit block address */
+	if (f2fs_test_bit(offset, sit_i->sit_bitmap))
+		blk_addr += sit_i->sit_blocks;
+
+	return blk_addr;
+}
+
+static inline pgoff_t next_sit_addr(struct f2fs_sb_info *sbi,
+						pgoff_t block_addr)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	block_addr -= sit_i->sit_base_addr;
+	if (block_addr < sit_i->sit_blocks)
+		block_addr += sit_i->sit_blocks;
+	else
+		block_addr -= sit_i->sit_blocks;
+
+	return block_addr + sit_i->sit_base_addr;
+}
+
+static inline void set_to_next_sit(struct sit_info *sit_i, unsigned int start)
+{
+	unsigned int block_off = SIT_BLOCK_OFFSET(sit_i, start);
+
+	if (f2fs_test_bit(block_off, sit_i->sit_bitmap))
+		f2fs_clear_bit(block_off, sit_i->sit_bitmap);
+	else
+		f2fs_set_bit(block_off, sit_i->sit_bitmap);
+}
+
+static inline unsigned long long get_mtime(struct f2fs_sb_info *sbi)
+{
+	struct sit_info *sit_i = SIT_I(sbi);
+	return sit_i->elapsed_time + CURRENT_TIME_SEC.tv_sec -
+						sit_i->mounted_time;
+}
+
+static inline void set_summary(struct f2fs_summary *sum, nid_t nid,
+			unsigned int ofs_in_node, unsigned char version)
+{
+	sum->nid = cpu_to_le32(nid);
+	sum->ofs_in_node = cpu_to_le16(ofs_in_node);
+	sum->version = version;
+}
+
+static inline block_t start_sum_block(struct f2fs_sb_info *sbi)
+{
+	return __start_cp_addr(sbi) +
+		le32_to_cpu(F2FS_CKPT(sbi)->cp_pack_start_sum);
+}
+
+static inline block_t sum_blk_addr(struct f2fs_sb_info *sbi, int base, int type)
+{
+	return __start_cp_addr(sbi) +
+		le32_to_cpu(F2FS_CKPT(sbi)->cp_pack_total_block_count)
+				- (base + 1) + type;
+}
-- 
1.7.9.5




---
Jaegeuk Kim
Samsung

