--CREATE PROCEDURE [dbo].[usp_CLO_Reinvestment_Algorithm_for_subject_PID]
--    @pid NVARCHAR(256),
 --   @ScenarioName nvarchar(256),
	--@UpdatedBy [nvarchar](256)
--AS

--BEGIN
    DECLARE @pid NVARCHAR(256) = 'LT0100' -- testing only
    DECLARE @ScenarioName nvarchar(256) = 'IBSM'
    DECLARE @UpdatedBy nvarchar(256) = 'vsubbotin'

    SET NOCOUNT ON;

    DECLARE @lid INT, @Scenario_ID int,
            @bu NVARCHAR(MAX), 
            @ppsplit DECIMAL(28, 15), 
            @clo_end_date DATETIME, 
            @clo_reinvestment_period_end DATETIME, 
            @LoanMaturityDate DATETIME,
            @loan_pdwn_amt DECIMAL(28, 15),
            @clo_bal DECIMAL(28, 15),
            @loan_bal DECIMAL(28, 15),
            @residual_amt DECIMAL(28, 15),
            @repo_name NVARCHAR(MAX),
            @repo_draw_amt DECIMAL(28, 15),
            @financing_bal_sum DECIMAL(28, 15);
    
    -- lookup correct LID associated with subject PID and Scenario Name
    SET @LID = ILAS.dbo.udf_GetLID(@PId,null,@ScenarioName);
    SET @Scenario_ID = (Select ScenarioID from ILSCommon..Scenario where ScenarioName = @ScenarioName)

    -- Remove prior entries generated by subject PID:
    DELETE FROM [ILAS].dbo.ProjectedRepoTransactions WHERE Comments = @lid

    -- check if PID is pledged to a CLO
    IF EXISTS (SELECT 1 FROM [ILAS].dbo.FinancingBUSetup WHERE [FinancingSourceName] LIKE '%CLO%' AND LID = @lid)
    BEGIN
        -- PID is pledged to a CLO, proceed with algorithm
        -- create cursor for FinancingSourceNames
        DECLARE FinancingCursor CURSOR FOR
        SELECT [FinancingSourceName], [BusinessUnit], PariPassuSplit, [MaturityDateUsed]
        FROM [ILAS].dbo.FinancingBUSetup
        WHERE LID = @lid and [FinancingSourceName] LIKE '%CLO%'
        
        OPEN FinancingCursor;

        -- declare variables to hold the current Financing cursor row
        DECLARE @currentFinancing NVARCHAR(MAX), 
        @currentBU NVARCHAR(MAX),
        @currentPPSplit DECIMAL(28, 15), 
        @currentMaturityDateUsed DATETIME;

        -- PID can be pledged to multiple CLO deals, which requires running a loop to go through all BUs which PID is pledged to:
        FETCH NEXT FROM FinancingCursor 
        INTO @currentFinancing, @currentBU, @currentPPSplit, @currentMaturityDateUsed;

        -- start loop
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- @currentFinancing is FinancingSourceName for current iteration
            SELECT 
                @bu = @currentBU, 
                @ppsplit = @currentPPSplit, 
                @clo_end_date = @currentMaturityDateUsed,
                @clo_reinvestment_period_end = 
                    CASE 
                        WHEN @currentFinancing = 'XYZ 2021-SIF1 CLO' THEN '2024-04-06'
                        WHEN @currentFinancing = 'XYZ 2021-SIF2 CLO' THEN '2025-01-10'
                        ELSE NULL
                    END

            -- STEP 2: identify the expected maturity date of the loan
            SELECT @LoanMaturityDate = MaturityDateUsed
            FROM [ILAS].dbo.MaturitySchedule ms
                INNER JOIN [ILSCommon].dbo.NoteCalc nc ON ms.LID = nc.LID
            WHERE ms.LID = @lid AND nc.ScenarioID = @Scenario_ID AND ms.ScheduleType = 'Expected Maturity date';

            -- PROCESS 2: no action if loan’s maturity is prior to CLO Reinvestment Period End Date
            IF @LoanMaturityDate <= @clo_reinvestment_period_end
            BEGIN
                -- exit algorithm
                CONTINUE;
            END

            -- PROCESS 3: end of reinvestment, before deal call
            IF @LoanMaturityDate > @clo_reinvestment_period_end AND @LoanMaturityDate <= @clo_end_date
            BEGIN
                -- get loan paydown amount at the time of loan's maturity
                SELECT @loan_pdwn_amt = [BeginningBalance] * @ppsplit
                FROM [ILSCommon].dbo.PeriodEndData
                WHERE [PeriodEndDate] = EoMonth(@LoanMaturityDate, 0) and ScenarioID = @Scenario_ID and LID = @lid
                
                -- get outstanding allocated CLO balance at the time of loan's maturity
                SELECT @clo_bal = [BeginningBalance]
                FROM [ILSCommon].dbo.FinancingPeriodEndDataBU
                WHERE [PeriodEndDate] = EoMonth(@LoanMaturityDate, 0) and ScenarioID = @Scenario_ID and LID = @lid
                    and BusinessUnit = @bu

                -- find residual 
                SET @residual_amt = @loan_pdwn_amt - @clo_bal;

                -- insert into transaction table allocated residual pdwn amount for all other PIDs pledged to given CLO deal
                -- get sum of all allocated CLO balances excluding subject PID
                SELECT @financing_bal_sum = SUM(BeginningBalance) 
                    FROM [ILSCommon].dbo.FinancingPeriodEndDataBU
                    WHERE ScenarioID = @Scenario_ID 
                        AND PeriodEndDate = EoMonth(@LoanMaturityDate, 0) 
                        AND BusinessUnit = @bu
                        AND LID <> @lid

                INSERT INTO [ILAS].dbo.ProjectedRepoTransactions ([LID], [Date], [RepoLineName], [Comments], [Amount],
                                                                    [CreatedBy], [CreatedDate], [UpdatedBy], [UpdatedDate])
                SELECT
                    LID AS [LID],
                    @LoanMaturityDate AS [Date],
                    @currentFinancing AS [RepoLineName],
                    @lid AS [Comments],
                    -@residual_amt * fd.FinancingBalance / @financing_bal_sum AS [Amount],
                    @UpdatedBy as [CreatedBy],
                    getdate() as [CreatedDate],
                    @UpdatedBy as [UpdatedBy],
                    getdate() as [UpdatedDate]
                FROM (
                    SELECT fped.LID,
                        SUM(fped.BeginningBalance) AS [FinancingBalance]
                    FROM [ILAS].dbo.FinancingBUSetup fbs
                        INNER JOIN [ILAS].dbo.Note n ON fbs.LID = n.LID
                        INNER JOIN [ILSCommon].dbo.FinancingPeriodEndDataBU fped ON fbs.LID = fped.LID and fbs.BusinessUnit = fped.BusinessUnit
                    WHERE fped.ScenarioID = @Scenario_ID 
                        AND fped.PeriodEndDate = EoMonth(@LoanMaturityDate, 0) 
                        AND fped.BusinessUnit = @bu
                        AND fbs.FinancingSourceName = @currentFinancing
                        AND fbs.LID <> @lid
                        AND n.Status = 'Active'
                    GROUP BY fped.LID
                    ) fd  
            END

            -- PROCESS 4: rollover after termination date
            IF @LoanMaturityDate > @clo_end_date
            BEGIN
                -- lookup outstanding clo balance allocated to subject PID at CLO termination date
                SELECT @clo_bal = [BeginningBalance]
                FROM [ILSCommon].dbo.FinancingPeriodEndDataBU
                WHERE [PeriodEndDate] = EoMonth(@clo_end_date, 0) 
                    and ScenarioID = @Scenario_ID and LID = @lid
                    and BusinessUnit = @bu

                -- lookup outstanding loan balance at CLO termination date
                SELECT @loan_bal = [BeginningBalance] * @ppsplit
                FROM [ILSCommon].dbo.PeriodEndData
                WHERE [PeriodEndDate] = EoMonth(@clo_end_date, 0) 
                    and ScenarioID = @Scenario_ID and LID = @lid
                
                -- Insert CLO paydown transaction:
                INSERT INTO [ILAS].dbo.ProjectedRepoTransactions ([LID], [Date], [RepoLineName], [Comments], [Amount], 
                                                                    [CreatedBy], [CreatedDate], [UpdatedBy], [UpdatedDate])
                SELECT
                    @lid AS [LID],
                    @clo_end_date AS [Date],
                    @currentFinancing AS [RepoLineName],
                    @lid AS [Comments],
                    -@clo_bal AS [Amount],
                    @UpdatedBy as [CreatedBy],
                    getdate() as [CreatedDate],
                    @UpdatedBy as [UpdatedBy],
                    getdate() as [UpdatedDate]
                SELECT @repo_name = [FinancingSourceName]
                    FROM [ILAS].dbo.FinancingBUSetup
                    WHERE LID = @lid and FinancingSourceName in ('DB Repo', 'BANA', 'MUFG Repo')
                    
                    IF @repo_name = 'DB Repo'
                        BEGIN
                            SET @repo_draw_amt = @loan_bal * 0.85
                        END
                    ELSE IF @repo_name = 'MUFG Repo' 
                        BEGIN
                            SET @repo_draw_amt = @loan_bal * 0.825
                        END
                    ELSE IF @repo_name = 'BANA'
                        BEGIN
                            SET @repo_draw_amt = @loan_bal * 0.825
                        END

                    -- Insert CLO paydown transaction:
                    INSERT INTO [ILAS].dbo.ProjectedRepoTransactions ([LID], [Date], [RepoLineName], [Comments], [Amount],
                                                                       [CreatedBy], [CreatedDate], [UpdatedBy], [UpdatedDate])
                    SELECT
                        @lid AS [LID],
                        @clo_end_date AS [Date],
                        @repo_name AS [RepoLineName],
                        @lid AS [Comments],
                        @repo_draw_amt AS [Amount],
                        @UpdatedBy as [CreatedBy],
                        getdate() as [CreatedDate],
                        @UpdatedBy as [UpdatedBy],
                        getdate() as [UpdatedDate]
   
            END;
            FETCH NEXT FROM FinancingCursor INTO @currentFinancing, @currentBU, @currentPPSplit, @currentMaturityDateUsed;
        END;

        CLOSE FinancingCursor;
        DEALLOCATE FinancingCursor;
    END