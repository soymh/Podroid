/*
 * Podroid - Rootless Podman for Android
 * Copyright (C) 2024-2026 Podroid contributors
 *
 * Full-VM backup: snapshots filesDir/storage.img (the persistent ext4 that
 * holds the overlay upper, container stores and migration markers) into
 * Downloads/Podroid/vm-backups, and restores it back. The system squashfs is
 * not included — it is replaced on every app update by design.
 */
package com.excp.podroid.data.repository

import android.content.Context
import android.os.Environment
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.excp.podroid.BuildConfig
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

data class VmBackupManifest(
    val flavor: String,
    val versionCode: Int,
    val storageSizeGb: Int,
    val createdMs: Long,
    val packageName: String,
)

data class VmBackupFile(
    val name: String,
    val sizeBytes: Long,
    val lastModifiedMs: Long,
    val absolutePath: String,
    val manifest: VmBackupManifest?,
)

@Singleton
class VmBackupRepository @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        const val VM_BACKUP_SUBDIR = "Podroid/vm-backups"
        const val STORAGE_IMG = "storage.img"
        const val IMAGE_EXT = ".img"
        const val MANIFEST_EXT = ".json"
        const val BACKUP_PREFIX = "podroid-vm-"
        // SEEK_* come from <fcntl.h> (stable Linux UAPI, never renumbered):
        // android.system.OsConstants does not expose them.
        const val SEEK_DATA = 3
        const val SEEK_HOLE = 4
    }

    fun backupDirectory(): File {
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        return File(downloads, VM_BACKUP_SUBDIR)
    }

    fun storageFile(): File = File(context.filesDir, STORAGE_IMG)

    fun isDownloadsReachable(): Boolean {
        val dir = backupDirectory()
        return runCatching { dir.exists() || dir.mkdirs() }.getOrDefault(false)
    }

    fun newBackupName(flavor: String): String {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val safeFlavor = flavor.ifBlank { "unknown" }.replace(Regex("[^A-Za-z0-9_-]"), "")
        return "$BACKUP_PREFIX$safeFlavor-$stamp$IMAGE_EXT"
    }

    fun listBackups(): List<VmBackupFile> {
        val dir = backupDirectory()
        if (!dir.isDirectory) return emptyList()
        return dir.listFiles()
            ?.filter { it.isFile && it.name.startsWith(BACKUP_PREFIX) && it.name.endsWith(IMAGE_EXT) }
            ?.map { f ->
                VmBackupFile(
                    name = f.name,
                    sizeBytes = f.length(),
                    lastModifiedMs = f.lastModified(),
                    absolutePath = f.absolutePath,
                    manifest = readManifest(manifestFor(f)),
                )
            }
            ?.sortedByDescending { it.lastModifiedMs }
            ?: emptyList()
    }

    fun manifestFor(image: File): File =
        File(image.parentFile, image.name.removeSuffix(IMAGE_EXT) + MANIFEST_EXT)

    fun readManifest(file: File): VmBackupManifest? {
        if (!file.isFile || !file.canRead()) return null
        return runCatching {
            val o = JSONObject(file.readText())
            VmBackupManifest(
                flavor = o.optString("flavor", "unknown"),
                versionCode = o.optInt("versionCode", 0),
                storageSizeGb = o.optInt("storageSizeGb", 0),
                createdMs = o.optLong("createdMs", file.lastModified()),
                packageName = o.optString("packageName", ""),
            )
        }.getOrNull()
    }

    fun writeManifest(file: File, manifest: VmBackupManifest) {
        val o = JSONObject()
            .put("flavor", manifest.flavor)
            .put("versionCode", manifest.versionCode)
            .put("storageSizeGb", manifest.storageSizeGb)
            .put("createdMs", manifest.createdMs)
            .put("packageName", manifest.packageName)
        file.writeText(o.toString(2))
    }

    fun currentManifest(storageSizeGb: Int): VmBackupManifest = VmBackupManifest(
        flavor = BuildConfig.FLAVOR,
        versionCode = BuildConfig.VERSION_CODE,
        storageSizeGb = storageSizeGb,
        createdMs = System.currentTimeMillis(),
        packageName = context.packageName,
    )

    /**
     * Copies [src] to [dst], preserving sparseness via SEEK_DATA/SEEK_HOLE so
     * a mostly-empty disk image backs up at (roughly) its used size instead
     * of its configured size. Falls back to a plain stream copy on
     * filesystems without hole support. Reports (done, total) bytes; honors
     * coroutine cancellation. Must run on Dispatchers.IO.
     */
    suspend fun sparseCopy(src: File, dst: File, onProgress: (Long, Long) -> Unit) {
        val total = src.length()
        withContext(Dispatchers.IO) {
            val scope = this
            val fallback: suspend () -> Unit = { copyStream(src, dst, total, onProgress, scope) }
            try {
                sparseCopySeek(src, dst, total, onProgress, scope)
            } catch (e: ErrnoException) {
                // NOTE: the "not supported" errno is EOPNOTSUPP in
                // android.system.OsConstants (there is no ENOTSUP there).
                if (e.errno == OsConstants.ENOSYS || e.errno == OsConstants.EINVAL ||
                    e.errno == OsConstants.EOPNOTSUPP
                ) {
                    fallback()
                } else {
                    throw e
                }
            }
        }
    }

    private suspend fun sparseCopySeek(
        src: File,
        dst: File,
        total: Long,
        onProgress: (Long, Long) -> Unit,
        scope: kotlinx.coroutines.CoroutineScope,
    ) {
        FileInputStream(src).use { fis ->
            FileOutputStream(dst).use { fos ->
                val inFd = fis.fd
                val outFd = fos.fd
                // Pre-size: ftruncate extends with holes (no allocation).
                Os.ftruncate(outFd, total)
                val buf = ByteArray(1024 * 1024)
                var off = 0L
                var done = 0L
                onProgress(0L, total)
                while (off < total) {
                    scope.ensureActive()
                    val dataOff = try {
                        Os.lseek(inFd, off, SEEK_DATA)
                    } catch (e: ErrnoException) {
                        if (e.errno == OsConstants.ENXIO) break else throw e
                    }
                    if (dataOff < 0 || dataOff >= total) break
                    val holeOff = try {
                        Os.lseek(inFd, dataOff, SEEK_HOLE)
                    } catch (e: ErrnoException) {
                        if (e.errno == OsConstants.ENXIO) total else throw e
                    }
                    var pos = dataOff
                    fis.channel.position(pos)
                    fos.channel.position(pos)
                    while (pos < holeOff) {
                        scope.ensureActive()
                        val n = fis.read(buf, 0, min(buf.size.toLong(), holeOff - pos).toInt())
                        if (n <= 0) break
                        fos.write(buf, 0, n)
                        pos += n
                        done += n
                    }
                    onProgress(min(done, total), total)
                    off = holeOff
                }
                fos.fd.sync()
                onProgress(total, total)
            }
        }
    }

    private suspend fun copyStream(
        src: File,
        dst: File,
        total: Long,
        onProgress: (Long, Long) -> Unit,
        scope: kotlinx.coroutines.CoroutineScope,
    ) {
        FileInputStream(src).channel.use { ic ->
            FileOutputStream(dst).channel.use { oc ->
                var done = 0L
                var n: Long
                val buf = java.nio.ByteBuffer.allocateDirect(1024 * 1024)
                onProgress(0L, total)
                while (true) {
                    scope.ensureActive()
                    buf.clear()
                    n = ic.read(buf).toLong()
                    if (n <= 0) break
                    buf.flip()
                    while (buf.hasRemaining()) oc.write(buf)
                    done += n
                    onProgress(min(done, total), total)
                }
                oc.force(true)
                onProgress(total, total)
            }
        }
    }

    /** Snapshot the live disk image. Caller must ensure the VM is stopped. */
    suspend fun backup(
        storageSizeGb: Int,
        onProgress: (Long, Long) -> Unit,
    ): Result<File> = runCatching {
        val src = storageFile()
        require(src.isFile) { "No VM disk image found" }
        val dir = backupDirectory()
        require(dir.exists() || dir.mkdirs()) { "Backup folder unreachable" }
        val dst = File(dir, newBackupName(BuildConfig.FLAVOR))
        sparseCopy(src, dst, onProgress)
        writeManifest(manifestFor(dst), currentManifest(storageSizeGb))
        dst
    }

    /**
     * Replace the live disk image with [backup]. Caller must ensure the VM is
     * stopped. The pre-existing image (if any) is rotated to storage.img.bak,
     * replacing any previous .bak — so one fallback generation always exists.
     */
    suspend fun restore(
        backup: File,
        onProgress: (Long, Long) -> Unit,
    ): Result<Unit> = runCatching {
        require(backup.isFile && backup.canRead()) { "Backup image unreadable" }
        val live = storageFile()
        val bak = File(live.parentFile, "$STORAGE_IMG.bak")
        if (live.exists()) {
            bak.delete()
            require(live.renameTo(bak)) { "Could not park current disk image" }
        }
        try {
            sparseCopy(backup, live, onProgress)
        } catch (e: Exception) {
            // Best-effort rollback so a failed restore never leaves no image.
            live.delete()
            bak.renameTo(live)
            throw e
        }
    }

    fun deleteBackup(backup: File): Boolean {
        val manifestDeleted = manifestFor(backup).let { if (it.exists()) it.delete() else true }
        return backup.delete() && manifestDeleted
    }

    fun formatSize(bytes: Long): String = when {
        bytes >= 1024L * 1024 * 1024 -> String.format(Locale.US, "%.1f GB", bytes / (1024.0 * 1024 * 1024))
        bytes >= 1024L * 1024 -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024))
        bytes >= 1024L -> String.format(Locale.US, "%.1f KB", bytes / 1024.0)
        else -> "$bytes B"
    }

    fun formatDate(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(ms))
}
