# Files is an app-bar route, not a persistent navigation destination

> Status: accepted

The Android app uses Home as its default operational surface and exposes Files
from the Home app bar as well as the Home **Send files** action. It does not use
a persistent bottom navigation bar for the two-destination app. This preserves
vertical space for sync status, the primary file action, and latest activity;
Files remains a first-class route without making low-level navigation compete
with the utility's job.

## Considered Options

- A persistent two-item Home/Files bottom navigation bar.
- Files hidden behind Settings or treated as a secondary utility.

The first adds permanent chrome for only two destinations. The second hides an
important manual workflow. The accepted middle path keeps Files prominent and
reachable without a persistent bar.
