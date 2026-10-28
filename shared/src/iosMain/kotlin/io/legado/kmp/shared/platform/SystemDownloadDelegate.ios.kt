@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import platform.Foundation.NSError
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionDownloadDelegateProtocol
import platform.Foundation.NSURLSessionDownloadTask
import platform.Foundation.NSURLSessionTask
import platform.darwin.NSObject

internal class SystemDownloadDelegate(private val owner: NativeSystemDownloadService) : NSObject(),
    NSURLSessionDownloadDelegateProtocol {
    override fun URLSession(
        session: NSURLSession,
        downloadTask: NSURLSessionDownloadTask,
        didFinishDownloadingToURL: NSURL,
    ) = owner.delivered(downloadTask, didFinishDownloadingToURL)

    override fun URLSession(
        session: NSURLSession,
        downloadTask: NSURLSessionDownloadTask,
        didWriteData: Long,
        totalBytesWritten: Long,
        totalBytesExpectedToWrite: Long,
    ) = owner.progress(downloadTask, totalBytesWritten, totalBytesExpectedToWrite)

    override fun URLSession(
        session: NSURLSession,
        downloadTask: NSURLSessionDownloadTask,
        didResumeAtOffset: Long,
        expectedTotalBytes: Long,
    ) = owner.progress(downloadTask, didResumeAtOffset, expectedTotalBytes)

    override fun URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError: NSError?) =
        owner.completed(task, didCompleteWithError)

    override fun URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) = owner.finishedEvents()
}
