#ifndef LEGADO_LIBARCHIVE_WRAPPER_H
#define LEGADO_LIBARCHIVE_WRAPPER_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

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

/* EPUB has an independent seekable ZIP entry point; the memory-backed RAR/7z ABI above is unchanged. */
typedef ssize_t legado_epub_read_callback(struct archive *, void *, const void **);
typedef int64_t legado_epub_skip_callback(struct archive *, void *, int64_t);
typedef int64_t legado_epub_seek_callback(struct archive *, void *, int64_t, int);
typedef int legado_epub_open_callback(struct archive *, void *);
typedef int legado_epub_close_callback(struct archive *, void *);
extern int archive_read_support_format_zip_seekable(struct archive *);
extern int archive_read_set_seek_callback(struct archive *, legado_epub_seek_callback *);
extern int archive_read_open2(struct archive *, void *, legado_epub_open_callback *,
    legado_epub_read_callback *, legado_epub_skip_callback *, legado_epub_close_callback *);
extern int archive_read_set_format_option(struct archive *, const char *, const char *, const char *);
extern const char *archive_format_name(struct archive *);
extern int64_t archive_filter_bytes(struct archive *, int);
extern void archive_set_error(struct archive *, int, const char *, ...);

static inline void *legado_epub_new(void) { return archive_read_new(); }
static inline int legado_epub_enable(void *a) {
    if (archive_read_support_filter_none(a) != 0) return -30;
    if (archive_read_support_format_zip_seekable(a) != 0) return -30;
    /* Do not inflate AppleDouble resources while merely enumerating headers. */
    if (archive_read_set_format_option(a, "zip", "mac-ext", NULL) != 0) return -30;
    return archive_read_set_format_option(a, "zip", "ignorecrc32", NULL);
}
static inline int legado_epub_open(void *a, void *client, legado_epub_read_callback *read_cb,
    legado_epub_skip_callback *skip_cb, legado_epub_seek_callback *seek_cb) {
    if (archive_read_set_seek_callback(a, seek_cb) != 0) return -30;
    return archive_read_open2(a, client, NULL, read_cb, skip_cb, NULL);
}
static inline void legado_epub_callback_error(void *a) {
    archive_set_error(a, EIO, "EPUB byte source callback failed");
}
static inline int legado_epub_next(void *a, void **entry) {
    return archive_read_next_header(a, (struct archive_entry **)entry);
}
static inline int64_t legado_epub_read(void *a, void *bytes, size_t size) {
    return (int64_t)archive_read_data(a, bytes, size);
}
static inline int legado_epub_skip(void *a) { return archive_read_data_skip(a); }
static inline int legado_epub_matches(void *a) { return (archive_format(a) & 0xFF0000) == 0x50000; }
static inline int legado_epub_encrypted(void *a) { return archive_read_has_encrypted_entries(a) > 0; }
static inline const char *legado_epub_format_name(void *a) { return archive_format_name(a); }
/* Consumed input position after a header is stable even when an earlier entry was read rather than skipped. */
static inline int64_t legado_epub_position(void *a) { return archive_filter_bytes(a, 0); }
static inline const char *legado_epub_path(void *entry) { return archive_entry_pathname_utf8(entry); }
static inline int64_t legado_epub_size(void *entry) { return archive_entry_size(entry); }
static inline int legado_epub_size_known(void *entry) { return archive_entry_size_is_set(entry); }
static inline int legado_epub_kind(void *entry) {
    if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) return 0;
    mode_t kind = archive_entry_filetype(entry);
    return kind == S_IFREG ? 1 : kind == S_IFDIR ? 2 : 0;
}
static inline int legado_epub_entry_encrypted(void *entry) { return archive_entry_is_encrypted(entry) > 0; }
static inline int legado_epub_close(void *a) { return archive_read_close(a); }
static inline int legado_epub_free(void *a) { return archive_read_free(a); }

#endif
