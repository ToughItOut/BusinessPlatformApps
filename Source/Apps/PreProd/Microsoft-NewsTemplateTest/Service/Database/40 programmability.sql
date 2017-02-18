SET ANSI_NULLS              ON;
SET ANSI_PADDING            ON;
SET ANSI_WARNINGS           ON;
SET ANSI_NULL_DFLT_ON       ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER       ON;
go

CREATE PROCEDURE bpst_news.sp_write_document
	-- Document parameters
	@docid NCHAR(64),
	@text NVARCHAR(max) NULL,
	@textLength INT NULL,
	@cleanedText NVARCHAR(max) NULL,
	@cleanedTextLength int NULL,
	@title NVARCHAR(2000) NULL,
	@sourceUrl NVARCHAR(2000) NULL,
	@sourceDomain NVARCHAR(1000) NULL,
	@category NVARCHAR(150) NULL,
	@imageUrl NVARCHAR(max) = NULL,
	@imageWidth INT = NULL,
	@imageHeight INT = NULL,
	@abstract NVARCHAR(4000) NULL,

	-- Published Timestamp
	@publishedTimestamp datetime,
	@publishedMonthPrecision datetime,
	@publishedWeekPrecision datetime,
	@publishedDayPrecision datetime,
	@publishedHourPrecision datetime,
	@publishedMinutePrecision datetime,

	-- Ingest Timestamp
	@ingestTimestamp datetime,
	@ingestMonthPrecision datetime,
	@ingestWeekPrecision datetime,
	@ingestDayPrecision datetime,
	@ingestHourPrecision datetime,
	@ingestMinutePrecision datetime,

	-- Sentiment
	@sentimentScore float,

	-- Key Phrases
	@keyPhraseJson NVARCHAR(max)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	-- Set XACT_ABORT to roll back any open transactions for most errors
	SET XACT_ABORT, NOCOUNT ON

	BEGIN TRANSACTION

	BEGIN TRY
		DELETE FROM [bpst_news].[documents] WHERE id = @docid;

		INSERT INTO [bpst_news].[documents] 
		( id, text, textLength,	cleanedText, cleanedTextLength, abstract, title, sourceUrl, sourceDomain, category, imageUrl, imageWidth, imageHeight )
		VALUES
		( @docid, @text, @textLength, @cleanedText, @cleanedTextLength, @abstract, @title, @sourceUrl, @sourceDomain, @category, @imageUrl, @imageWidth, @imageHeight );

		DELETE FROM [bpst_news].[documentpublishedtimes] WHERE id = @docid;
		INSERT INTO [bpst_news].[documentpublishedtimes]
		( id, "timestamp", monthPrecision, weekPrecision, dayPrecision, hourPrecision, minutePrecision )
		VALUES
		( @docId, @publishedTimestamp, @publishedMonthPrecision, @publishedWeekPrecision, @publishedDayPrecision, @publishedHourPrecision, @publishedMinutePrecision );

		DELETE FROM [bpst_news].[documentingestedtimes] WHERE id = @docid;
		INSERT INTO [bpst_news].[documentingestedtimes]
		( id, "timestamp", monthPrecision, weekPrecision, dayPrecision, hourPrecision, minutePrecision )
		VALUES
		( @docId, @ingestTimestamp, @ingestMonthPrecision, @ingestWeekPrecision, @ingestDayPrecision, @ingestHourPrecision, @ingestMinutePrecision );

		DELETE FROM [bpst_news].[documentsentimentscores] WHERE id = @docid;
		INSERT INTO [bpst_news].[documentsentimentscores] (id, score) VALUES ( @docid, @sentimentScore );

		DELETE FROM [bpst_news].[documentkeyphrases] WHERE documentId = @docid;

		INSERT INTO [bpst_news].[documentkeyphrases] (documentId, phrase)
		SELECT @docid AS documentId, value AS phrase
		FROM OPENJSON(@keyPhraseJson);

		COMMIT TRANSACTION;
	END TRY
	BEGIN CATCH
		IF @@trancount > 0 ROLLBACK TRANSACTION
		DECLARE @msg nvarchar(2048) = error_message()
		RAISERROR (@msg, 16, 1)
	END CATCH
END;
go

CREATE PROCEDURE bpst_news.sp_get_replication_counts AS
BEGIN
    SET NOCOUNT ON;

    SELECT UPPER(LEFT(ta.name, 1)) + LOWER(SUBSTRING(ta.name, 2, 100)) AS EntityName, SUM(pa.[rows]) AS [Count]
    FROM sys.tables ta INNER JOIN sys.partitions pa ON pa.[OBJECT_ID] = ta.[OBJECT_ID]
                        INNER JOIN sys.schemas sc ON ta.[schema_id] = sc.[schema_id]
    WHERE
        sc.name='bpst_news' AND ta.is_ms_shipped = 0 AND pa.index_id IN (0,1) AND
        ta.name IN ('documents', 'documentpublishedtimes', 'documentingestedtimes', 'documentkeyphrases','documentsentimentscores', 'documenttopics', 'documenttopicimages', 'entities', 'documentcompressedentities')
    GROUP BY ta.name
END;
go

CREATE PROCEDURE bpst_news.sp_get_prior_content AS
BEGIN
    SET NOCOUNT ON;

    SELECT Count(*) AS ExistingObjectCount
    FROM   information_schema.tables
    WHERE  ( table_schema = 'bpst_news' AND
             table_name IN ('configuration', 'date', 'documents', 'documentpublishedtimes', 'documentingestedtimes', 'documentkeyphrases', 'documentsentimentscores', 'documenttopics', 'documenttopicimages', 'entities', 'documentcompressedentities', 'stg_documenttopics', 'stg_documenttopicimages', 'stg_entities', 'stg_documentcompressedentities')
           );
END;
go



-- Description:	Truncates all batch process tables so batch processes can be run
CREATE PROCEDURE  bpst_news.sp_clean_stage_tables
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;

    -- These tables are populated by AzureML batch processes.
    TRUNCATE TABLE bpst_news.stg_entities;
    TRUNCATE TABLE bpst_news.stg_documentcompressedentities;
    TRUNCATE TABLE bpst_news.stg_documenttopics;
    TRUNCATE TABLE bpst_news.stg_documenttopicimages;
END;
go

CREATE PROCEDURE  bpst_news.sp_mergedata
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;

    TRUNCATE TABLE bpst_news.entities;
    INSERT INTO bpst_news.entities WITH (TABLOCK) (documentId, entityType, entityValue, offset, offsetDocumentPercentage, [length])
        SELECT documentId, entityType, entityValue, offset, offsetDocumentPercentage, [length] FROM bpst_news.stg_entities;

    TRUNCATE TABLE bpst_news.documentcompressedentities;
    INSERT INTO bpst_news.documentcompressedentities WITH (TABLOCK) (documentId, compressedEntitiesJson)
        SELECT documentId, compressedEntitiesJson FROM bpst_news.stg_documentcompressedentities;

    TRUNCATE TABLE bpst_news.documenttopics;
    INSERT INTO bpst_news.documenttopics WITH (TABLOCK) (documentId, topicId, batchId, documentDistance, topicScore, topicKeyPhrase)
        SELECT documentId, topicId, batchId, documentDistance, topicScore, topicKeyPhrase FROM bpst_news.stg_documenttopics;

    TRUNCATE TABLE bpst_news.documenttopicimages;
    INSERT INTO bpst_news.documenttopicimages WITH (TABLOCK) (topicId, imageUrl1, imageUrl2, imageUrl3, imageUrl4)
        SELECT topicId, imageUrl1, imageUrl2, imageUrl3, imageUrl4 FROM bpst_news.stg_documenttopicimages;
END;
go


CREATE PROCEDURE  bpst_news.sp_create_topic_key_phrase
AS
BEGIN
/****** Script for SelectTopNRows command from SSMS  ******/
DECLARE @KeyPhraseFrequency TABLE
(
	documentId CHAR(64),
	phrase VARCHAR(2000),
	phraseFrequency INT
);

-- Compute Document Key Phrase Frequency
INSERT @KeyPhraseFrequency
select 
	documentId,
	phrase,
	(totalLength - textWithoutPhrase) / phraseLength AS phraseFrequency
FROM 
(
	SELECT [documentId]
      ,[phrase]
	  ,len(convert(VARCHAR(MAX), t1.cleanedText)) totalLength
	  ,len(replace(convert(VARCHAR(MAX), t1.cleanedText), phrase, '')) textWithoutPhrase
	  ,len(t0.phrase) phraseLength
	FROM bpst_news.documentkeyphrases t0
	INNER JOIN Documents t1 ON t0.documentId = t1.id
) innerTable
WHERE phraseLength != 0;

-- Compute the score for each phrase.  Score = documentDistance * phraseFrequency
-- Sum each unique topic/phrase combination to get the total score for each phrase within a topic
DECLARE @DocumentTopicPhraseScore TABLE
(
	topicId INT,
	phrase VARCHAR(2000),
	phraseScore FLOAT
);

INSERT @DocumentTopicPhraseScore
SELECT topicId, phrase, SUM(phraseScore) AS PhraseScore FROM
(
	SELECT topicId, phrase, documentDistance * phraseFrequency AS phraseScore
	FROM bpst_news.documenttopics t0
	INNER JOIN @KeyPhraseFrequency t1 ON t0.documentId = t1.documentId
) t1
GROUP BY topicId, phrase

-- Drop the table if it exists
IF object_id(N'bpst_news.topickeyphrases', 'U') IS NOT NULL
	DROP TABLE bpst_news.topickeyphrases

-- Compute the final key phrase as the top three document key phrases
SELECT topicId, CONCAT([1], COALESCE(', ' + [2], ''), COALESCE(', ' + [3], '')) KeyPhrase
INTO bpst_news.topickeyphrases
FROM
(
	SELECT topicId, phrase, [rank] FROM
	(
		SELECT topicId, phrase, ROW_NUMBER() OVER (PARTITION BY topicId ORDER BY phraseScore DESC) [Rank]
		FROM @DocumentTopicPhraseScore
	) t0 WHERE [Rank] <= 3
) t1
PIVOT
(
	MAX(phrase) FOR [Rank] IN ([1], [2], [3])
) AS PivotTable

END;
go
