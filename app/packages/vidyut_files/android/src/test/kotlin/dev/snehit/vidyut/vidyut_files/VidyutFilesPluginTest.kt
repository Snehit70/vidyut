package dev.snehit.vidyut.vidyut_files

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Test

class VidyutFilesPluginTest {
    @Test
    fun folderPathSplitsIntoSegmentsAndRefusesClimbing() {
        assertEquals(listOf("Trip", "Day 1"), VidyutFolderPath.segments("Trip/Day 1"))
        assertEquals(null, VidyutFolderPath.segments("Trip/../.."))
        assertEquals(null, VidyutFolderPath.segments("/etc"))
        assertEquals(null, VidyutFolderPath.segments("Trip//Day"))
        assertEquals(null, VidyutFolderPath.segments("Trip\\Day"))
        assertEquals(null, VidyutFolderPath.segments(""))
    }

    @Test
    fun sourceGrantUsesOnlyReturnedReadPermission() {
        val returned =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        assertEquals(
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
            VidyutFileGrantFlags.sourceFlags(returned),
        )
    }

    @Test
    fun destinationGrantPreservesOnlyReturnedReadWritePermissions() {
        val returned =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION

        assertEquals(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            VidyutFileGrantFlags.destinationFlags(returned),
        )
    }

    @Test
    fun missingReadGrantDoesNotAttemptToPersistSourceAccess() {
        assertEquals(0, VidyutFileGrantFlags.sourceFlags(0))
        assertEquals(
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            VidyutFileGrantFlags.destinationFlags(
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            ),
        )
    }
}
