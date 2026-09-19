package com.excp.podroid.ui.screens.backup

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.excp.podroid.R
import com.excp.podroid.data.repository.ContainerBackupFile
import com.excp.podroid.data.repository.ContainerBackupRepository
import com.excp.podroid.data.repository.SettingsRepository
import com.excp.podroid.data.repository.VmBackupFile
import com.excp.podroid.data.repository.VmBackupRepository
import com.excp.podroid.engine.VmEngine
import com.excp.podroid.engine.VmState
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

data class ContainerBackupUiState(
    val vmRunning: Boolean = false,
    val vmStopped: Boolean = true,
    val storageAccessEnabled: Boolean = false,
    val guestPath: String = "/var/backups/podroid",
    val backupFiles: List<ContainerBackupFile> = emptyList(),
    val containerName: String = "",
    val imageRef: String = "",
    val vmBackups: List<VmBackupFile> = emptyList(),
    val vmProgress: Float? = null,
    val vmMessage: String? = null,
)

@HiltViewModel
class ContainerBackupViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val repository: ContainerBackupRepository,
    private val vmBackupRepository: VmBackupRepository,
    private val settingsRepository: SettingsRepository,
    private val engine: VmEngine,
) : ViewModel() {

    private val _containerName = MutableStateFlow("")
    private val _imageRef = MutableStateFlow("")
    private val _backupFiles = MutableStateFlow<List<ContainerBackupFile>>(emptyList())
    private val _vmBackups = MutableStateFlow<List<VmBackupFile>>(emptyList())
    private val _vmProgress = MutableStateFlow<Float?>(null)
    private val _vmMessage = MutableStateFlow<String?>(null)
    private var armedRestoreName: String? = null
    private var armedRestoreAtMs: Long = 0L

    val uiState: StateFlow<ContainerBackupUiState> = combine(
        engine.state,
        settingsRepository.storageAccessEnabled,
        _containerName,
        _imageRef,
        _backupFiles,
        _vmBackups,
        _vmProgress,
        _vmMessage,
    ) { vmState, storageAccess, container, image, files, vmFiles, vmProgress, vmMessage ->
        ContainerBackupUiState(
            vmRunning = vmState is VmState.Running,
            vmStopped = vmState is VmState.Idle || vmState is VmState.Stopped || vmState is VmState.Error,
            storageAccessEnabled = storageAccess,
            guestPath = repository.guestBackupPathLabel(storageAccess),
            backupFiles = files,
            containerName = container,
            imageRef = image,
            vmBackups = vmFiles,
            vmProgress = vmProgress,
            vmMessage = vmMessage,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ContainerBackupUiState())

    init {
        refresh()
        refreshVmBackups()
    }

    fun refresh() {
        _backupFiles.value = repository.listBackupFiles()
    }

    fun setContainerName(value: String) {
        _containerName.value = value
    }

    fun setImageRef(value: String) {
        _imageRef.value = value
    }

    fun copyExportCommand(): Boolean {
        val name = _containerName.value.trim()
        if (name.isEmpty()) return false
        copyToClipboard(repository.exportCommand(name))
        return true
    }

    fun copySaveCommand(): Boolean {
        val ref = _imageRef.value.trim()
        if (ref.isEmpty()) return false
        copyToClipboard(repository.saveImageCommand(ref))
        return true
    }

    fun copyListCommand() {
        copyToClipboard(repository.listCommand())
    }

    fun copyAllCommand() {
        copyToClipboard("podroid-backup all")
    }

    fun formatSize(bytes: Long): String = repository.formatSize(bytes)

    fun formatDate(ms: Long): String = repository.formatDate(ms)

    fun refreshVmBackups() {
        _vmBackups.value = vmBackupRepository.listBackups()
    }

    fun clearVmMessage() {
        _vmMessage.value = null
    }

    private fun vmOperationAllowed(): Boolean {
        // Re-read instead of trusting the composed snapshot: the VM must be
        // stopped right now (a live ext4 copy/restore risks corruption).
        val state = engine.state.value
        val stopped = state is VmState.Idle || state is VmState.Stopped || state is VmState.Error
        if (!stopped) _vmMessage.value = context.getString(R.string.vm_backup_stopped_only)
        return stopped && _vmProgress.value == null
    }

    fun backupVm() {
        if (!vmOperationAllowed()) return
        if (!vmBackupRepository.isDownloadsReachable()) {
            _vmMessage.value = context.getString(R.string.vm_backup_unreachable)
            return
        }
        viewModelScope.launch {
            _vmProgress.value = 0f
            _vmMessage.value = null
            val storageGb = settingsRepository.getStorageSizeGbSnapshot()
            val result = vmBackupRepository.backup(storageGb) { done, total ->
                _vmProgress.value = if (total > 0) done.toFloat() / total else 0f
            }
            _vmProgress.value = null
            result
                .onSuccess {
                    refreshVmBackups()
                    _vmMessage.value = context.getString(
                        R.string.vm_backup_success,
                        vmBackupRepository.formatSize(it.length()),
                    )
                }
                .onFailure {
                    _vmMessage.value = context.getString(
                        R.string.vm_backup_failed,
                        it.message ?: it.javaClass.simpleName,
                    )
                }
        }
    }

    /**
     * Two-step restore: first tap arms (names the file, 15s window), second
     * tap executes. Destructive (replaces storage.img), so no single-tap.
     */
    fun restoreVm(file: VmBackupFile) {
        if (!vmOperationAllowed()) return
        val now = System.currentTimeMillis()
        if (armedRestoreName != file.name || now - armedRestoreAtMs > 15_000) {
            armedRestoreName = file.name
            armedRestoreAtMs = now
            _vmMessage.value = context.getString(R.string.vm_backup_confirm_restore, file.name)
            return
        }
        armedRestoreName = null
        viewModelScope.launch {
            _vmProgress.value = 0f
            _vmMessage.value = null
            val result = vmBackupRepository.restore(File(file.absolutePath)) { done, total ->
                _vmProgress.value = if (total > 0) done.toFloat() / total else 0f
            }
            _vmProgress.value = null
            if (result.isSuccess) {
                // Adopt the backup's size so the next boot's ensureStorageImage
                // neither shrinks (never) nor pointlessly regrows the image.
                val sizeGb = file.manifest?.storageSizeGb ?: 0
                if (sizeGb > 0) settingsRepository.setStorageSizeGb(sizeGb)
                refreshVmBackups()
                _vmMessage.value = context.getString(R.string.vm_restore_success)
            } else {
                _vmMessage.value = context.getString(
                    R.string.vm_backup_failed,
                    result.exceptionOrNull()?.message ?: "?",
                )
            }
        }
    }

    fun deleteVmBackup(file: VmBackupFile) {
        if (_vmProgress.value != null) return
        if (vmBackupRepository.deleteBackup(File(file.absolutePath))) refreshVmBackups()
    }

    private fun copyToClipboard(text: String) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("podroid-backup", text))
    }
}
