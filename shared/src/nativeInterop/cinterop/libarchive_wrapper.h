#ifndef LEGADO_LIBARCHIVE_WRAPPER_H
#define LEGADO_LIBARCHIVE_WRAPPER_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>

/* Opaque public libarchive ABI, exported by the iOS SDK's libarchive.tbd.
 * Declarations match libarchive/archive.h and archive_entry.h (BSD licensed):
 * https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive
 * No private Apple symbols, dynamic lookup, filesystem extraction, or external filters.
 */
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_none(struct archive *);
extern int archive_read_support_format_7zip(struct archive *);
extern int archive_read_support_format_rar(struct archive *);
extern int archive_read_support_format_rar5(struct archive *);
extern int archive_read_open_memory(struct archive *, const void *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_has_encrypted_entries(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern int archive_format(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern int archive_entry_size_is_set(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);

static inline void *legado_archive_new(void) { return archive_read_new(); }
static inline int legado_archive_enable(void *a, int format) {
    if (archive_read_support_filter_none(a) != 0) return -30;
    if (format == 1) return archive_read_support_format_7zip(a);
    if (format != 2 || archive_read_support_format_rar(a) != 0) return -30;
    return archive_read_support_format_rar5(a);
}
static inline int legado_archive_open(void *a, const void *bytes, size_t size) {
    return archive_read_open_memory(a, bytes, size);
}
static inline int legado_archive_next(void *a, void **entry) {
    return archive_read_next_header(a, (struct archive_entry **)entry);
}
static inline int64_t legado_archive_read(void *a, void *bytes, size_t size) {
    return (int64_t)archive_read_data(a, bytes, size);
}
static inline int legado_archive_skip(void *a) { return archive_read_data_skip(a); }
static inline int legado_archive_encrypted(void *a) { return archive_read_has_encrypted_entries(a) > 0; }
static inline int legado_archive_matches(void *a, int format) {
    int detected = archive_format(a) & 0xFF0000;
    return format == 1 ? detected == 0xE0000 : (detected == 0xD0000 || detected == 0x100000);
}
static inline const char *legado_archive_path(void *entry) { return archive_entry_pathname_utf8(entry); }
static inline int64_t legado_archive_size(void *entry) { return archive_entry_size(entry); }
static inline int legado_archive_size_known(void *entry) { return archive_entry_size_is_set(entry); }
static inline int legado_archive_kind(void *entry) {
    if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) return 0;
    mode_t kind = archive_entry_filetype(entry);
    return kind == S_IFREG ? 1 : kind == S_IFDIR ? 2 : 0;
}
static inline int legado_archive_entry_encrypted(void *entry) { return archive_entry_is_encrypted(entry) > 0; }
static inline int legado_archive_close(void *a) { return archive_read_close(a); }
static inline int legado_archive_free(void *a) { return archive_read_free(a); }

#endif
