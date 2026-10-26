-- ================================================================
-- Table loaded daily by main.py (Simpro job schedules, next 30 days).
-- main.py deletes all rows and reloads them on every run.
-- Safe to re-run: only creates the table if it doesn't exist yet.
-- ================================================================

IF OBJECT_ID('specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days', 'U') IS NULL
BEGIN
    CREATE TABLE specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days (
        ScheduleID    INT            NOT NULL PRIMARY KEY,
        [Date]        DATE           NOT NULL,
        [Type]        NVARCHAR(20)   NULL,
        Reference     NVARCHAR(50)   NULL,
        JobID         INT            NULL,
        CostCenterID  INT            NULL,
        StaffID       INT            NULL,
        StaffName     NVARCHAR(200)  NULL,
        StaffType     NVARCHAR(50)   NULL,
        StartTime     TIME(0)        NULL,   -- earliest start of the day's schedule
        EndTime       TIME(0)        NULL,   -- latest end of the day's schedule
        TotalHours    FLOAT          NULL,
        LoadedAt      DATETIME2(0)   NOT NULL -- Melbourne time of the load
    );

    CREATE INDEX IX_Simpro_Schedules_Next30Days_Date  ON specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days ([Date]);
    CREATE INDEX IX_Simpro_Schedules_Next30Days_JobID ON specialisedspdr_sp_readwrite.Simpro_Schedules_Next30Days (JobID);
END;
