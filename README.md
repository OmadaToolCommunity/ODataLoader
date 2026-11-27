# ODataLoader
The ODataLoader is a utility for performing bulk Create/Update/Delete operations on Data Objects in Omada Cloud and OnPrem.
Data is read from CSV files or from OData or using a SQL query on a Omada database (cloud) or SQL server.
Data is mapped to Omada objects in a config file.
Large scale imports with long run-times is supported with a built-in status tracking mechanism that allow for resuming in case of failure and re-running the operations on failed entries with extensive logging for post processing failed entries.