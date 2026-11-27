return @"
select top 500
_id
,identityid
, _uid as IdentityUid
, _displayname
, email
, IDENTITYSTATUS_ENGLISH
, IDENTITYCATEGORY_ENGLISH
, VALIDFROM
, VALIDTO
, OUREF_VALUE 'Org Unit'
, employeeid
from tblidentity 
where _deletetime is null
and _id>$lastIdentifier
order by _id
"@