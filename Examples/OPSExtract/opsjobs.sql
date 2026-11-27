select top 500
	  TargetSystems.name as SystemName
	  ,SUBSTRING(OriginJobId,CHARINDEX('IdentityUId=',OriginJobId)+12,CHARINDEX(';Calcula',OriginJobId)-CHARINDEX('IdentityUId=',OriginJobId)-12) as IdentityUid
	  ,SUBSTRING(OriginJobId,10,CHARINDEX('IdentityUId=',OriginJobId)-11) as IdentityName 
	  ,t.objectid
	  ,CASE SUBSTRING([ObjectTypeName],0,13) WHEN 'ROPE_Account' THEN 'Account'  WHEN 'ROPE_Assignm' THEN 'Assignment'  ELSE 'Unknown'  END AS ObjectType
	  ,CASE T.Operation WHEN 0 THEN 'Create' WHEN 1 THEN 'Modify' WHEN 2 THEN 'Delete Assignment' WHEN 4 THEN 'Delete Account' ELSE 'Unknown' END AS TaskOperation
	,t.description as 'description'
	,j.id as jobid
	,x.ResourceName
	,y.Disabled
	,j.latestnotification
from jobs j
JOIN tasks t ON j.id=t.job_id
JOIN TargetSystems on j.targetsystem_id=TargetSystems.id
JOIN 
	(
	select TaskPropertyValue_PropertyValue_Id,[value] as ResourceName
	FROM [PropertyDefinitions] propdef
	JOIN [PropertyValues] propval
	ON propdef.id=propval.PropertyDefinition_Id
	where propdef.name='ROPE_Resource'
	) x
ON x.TaskPropertyValue_PropertyValue_Id=t.Id
JOIN 
	(
	select TaskPropertyValue_PropertyValue_Id,[value] as [Disabled]
	FROM [PropertyDefinitions] propdef
	JOIN [PropertyValues] propval
	ON propdef.id=propval.PropertyDefinition_Id
	where propdef.name='ROPE_Disabled'
	) y
ON y.TaskPropertyValue_PropertyValue_Id=t.Id
where j.status=5 --review (1=completed)
order by j.id