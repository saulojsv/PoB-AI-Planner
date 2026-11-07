Set-StrictMode -Version Latest
$script:ImportProductToken = 'PoBManualBuildImporter'

function Get-PoBImportSha256([string]$Text) {
	$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
	return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertTo-PoBImportUrl([string]$InputUrl) {
	if ([string]::IsNullOrWhiteSpace($InputUrl)) { return $null }
	$value = [Net.WebUtility]::HtmlDecode($InputUrl.Trim())
	if ($value.StartsWith('//')) { $value = 'https:' + $value }
	$uri = $null
	if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) { return $null }
	if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Port -ne 443) { return $null }
	$hostName = $uri.IdnHost.ToLowerInvariant().TrimEnd('.')
	if (-not $hostName -or $hostName -notmatch '\.') { return $null }
	if ($hostName -eq 'localhost' -or $hostName.EndsWith('.localhost') -or $hostName.EndsWith('.local') -or $hostName.EndsWith('.internal')) { return $null }
	$builder = [UriBuilder]::new($uri)
	$builder.Host = $hostName
	$builder.UserName = ''
	$builder.Password = ''
	$builder.Fragment = ''
	$canonical = $builder.Uri.AbsoluteUri
	if ($canonical.EndsWith('?')) { $canonical = $canonical.Substring(0, $canonical.Length - 1) }
	return $canonical
}

function Test-PoBImportPublicAddress([Net.IPAddress]$Address) {
	if ([Net.IPAddress]::IsLoopback($Address)) { return $false }
	$bytes = $Address.GetAddressBytes()
	if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
		$a = [int]$bytes[0]; $b = [int]$bytes[1]
		if ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224) { return $false }
		if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $false }
		if ($a -eq 169 -and $b -eq 254) { return $false }
		if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $false }
		if ($a -eq 192 -and $b -eq 168) { return $false }
		if ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) { return $false }
		return $true
	}
	if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
		if ($Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or $Address.IsIPv6Multicast) { return $false }
		if (($bytes[0] -band 0xFE) -eq 0xFC) { return $false }
		if ($Address.Equals([Net.IPAddress]::IPv6Any) -or $Address.Equals([Net.IPAddress]::IPv6Loopback)) { return $false }
		if ($Address.IsIPv4MappedToIPv6) { return Test-PoBImportPublicAddress $Address.MapToIPv4() }
		return $true
	}
	return $false
}

function Test-PoBImportPublicHost([string]$HostName) {
	if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
	$hostValue = $HostName.TrimEnd('.').ToLowerInvariant()
	if ($hostValue -eq 'localhost' -or $hostValue.EndsWith('.localhost') -or $hostValue.EndsWith('.local') -or $hostValue.EndsWith('.internal')) { return $false }
	try {
		$addresses = [Net.Dns]::GetHostAddresses($hostValue)
		if (@($addresses).Count -eq 0) { return $false }
		foreach ($address in $addresses) { if (-not (Test-PoBImportPublicAddress $address)) { return $false } }
		return $true
	} catch { return $false }
}

function Get-PoBImportRobotsPolicy([string]$Content, [string]$ProductToken = $script:ImportProductToken) {
	$groups = [Collections.Generic.List[object]]::new()
	$sitemaps = [Collections.Generic.List[string]]::new()
	$current = $null
	$hasDirective = $false
	foreach ($line in ($Content -split '\r?\n')) {
		$clean = ($line -split '#', 2)[0].Trim()
		if (-not $clean) { continue }
		if ($clean -match '^(?i)Sitemap:\s*(\S+)\s*$') {
			$normalized = ConvertTo-PoBImportUrl $Matches[1]
			if ($normalized) { $sitemaps.Add($normalized) }
			continue
		}
		if ($clean -match '^(?i)User-agent:\s*(.+)$') {
			if ($null -eq $current -or $hasDirective) {
				$current = [pscustomobject]@{
					Agents = [Collections.Generic.List[string]]::new()
					Rules = [Collections.Generic.List[object]]::new()
					CrawlDelay = 0.0
				}
				$groups.Add($current)
				$hasDirective = $false
			}
			$current.Agents.Add($Matches[1].Trim())
			continue
		}
		if ($null -eq $current) { continue }
		if ($clean -match '^(?i)(Allow|Disallow):\s*(.*)$') {
			$current.Rules.Add([pscustomobject]@{ Kind = $Matches[1].ToLowerInvariant(); Rule = $Matches[2].Trim() })
			$hasDirective = $true
			continue
		}
		if ($clean -match '^(?i)Crawl-delay:\s*(\d+(?:\.\d+)?)\s*$') {
			$parsed = 0.0
			if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
				$current.CrawlDelay = [Math]::Max([double]$current.CrawlDelay, $parsed)
			}
			$hasDirective = $true
		}
	}
	$matching = @($groups | Where-Object {
		@($_.Agents | Where-Object { $_ -eq '*' -or $_.Equals($ProductToken, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
	})
	$exact = @($matching | Where-Object { @($_.Agents | Where-Object { $_.Equals($ProductToken, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 })
	if ($exact.Count -gt 0) { $matching = $exact } else { $matching = @($matching | Where-Object { @($_.Agents | Where-Object { $_ -eq '*' }).Count -gt 0 }) }
	$rules = [Collections.Generic.List[object]]::new()
	$delay = 0.0
	foreach ($group in $matching) {
		foreach ($rule in $group.Rules) { $rules.Add($rule) }
		$delay = [Math]::Max($delay, [double]$group.CrawlDelay)
	}
	return [pscustomobject]@{
		Rules = @($rules)
		SitemapUrls = @($sitemaps | Select-Object -Unique)
		CrawlDelaySeconds = $delay
	}
}

function Test-PoBImportRobotsPath([object[]]$Rules, [string]$PathAndQuery) {
	$matches = @($Rules | Where-Object {
		if (-not $_.Rule) { return $false }
		$escaped = [regex]::Escape($_.Rule).Replace('\*', '.*')
		$pattern = '^' + $escaped
		if ($_.Rule.EndsWith('$')) { $pattern = '^' + $escaped.Substring(0, $escaped.Length - 2) + '$' }
		$PathAndQuery -match $pattern
	} | Sort-Object { $_.Rule.Length } -Descending)
	if ($matches.Count -eq 0) { return $true }
	$longest = $matches[0].Rule.Length
	$best = @($matches | Where-Object { $_.Rule.Length -eq $longest })
	return @($best | Where-Object Kind -eq 'allow').Count -gt 0
}

function Get-PoBImportCandidatesFromHtml([string]$Html, [string]$PageUrl, [string]$PageTitle = '') {
	$candidates = [Collections.Generic.List[object]]::new()
	$links = [Collections.Generic.List[object]]::new()
	$currentPage = ConvertTo-PoBImportUrl $PageUrl
	$searchableHtml = [Net.WebUtility]::HtmlDecode($Html)
	$searchableHtml = $searchableHtml -replace '\\/', '/' -replace '(?i)\\u002f', '/' -replace '(?i)\\u003a', ':' -replace '(?i)\\u0026', '&'
	$providerPatterns = @(
		[pscustomobject]@{ Name = 'PoBCodes'; Host = 'pob.codes'; Path = '/b/'; Pattern = '(?i)https://(?:www\.)?pob\.codes/b/(?<id>[A-Za-z0-9_-]{3,64})' },
		[pscustomobject]@{ Name = 'PoeNinja'; Host = 'poe.ninja'; Path = '/poe1/pob/'; Pattern = '(?i)https://(?:www\.)?poe\.ninja/poe1/pob/(?<id>[A-Za-z0-9_-]{3,64})' },
		[pscustomobject]@{ Name = 'PoEDB'; Host = 'poedb.tw'; Path = '/pob/'; Pattern = '(?i)https://(?:www\.)?poedb\.tw/pob/(?<id>[A-Za-z0-9_-]{3,64})' },
		[pscustomobject]@{ Name = 'PoBBinPage'; Host = 'pobb.in'; Path = '/'; Pattern = '(?i)https://(?:www\.)?pobb\.in/(?<id>[A-Za-z0-9_-]{3,64})(?:[/?#\s"''\\]|$)' }
	)
	foreach ($provider in $providerPatterns) {
		if ($currentPage -match $provider.Pattern) {
			$id = $Matches['id']
			$candidates.Add([pscustomobject]@{
				providerId = $provider.Name; id = $id; title = if ($PageTitle) { $PageTitle } else { $id }
				creator = ''; locale = ''; claimedLeague = ''; claimedPatch = $null
				claimedMainSkill = $null; sourceUrl = $currentPage; creatorUrl = ''
				rightsStatus = 'unverified'; rightsEvidenceUrl = ''
				acquisitionMethod = 'manual_selected_source_page'
				discoveryPageUrl = $currentPage; discoveredBuildUrl = $currentPage
			})
			break
		}
	}
	# Some guides and video pages keep PoB share links in JSON/script payloads
	# instead of anchors. Extract only known provider routes from decoded HTML.
	foreach ($provider in $providerPatterns) {
		foreach ($providerMatch in [regex]::Matches($searchableHtml, $provider.Pattern)) {
			$id = [string]$providerMatch.Groups['id'].Value
			if (-not $id) { continue }
			$candidates.Add([pscustomobject]@{
				providerId = $provider.Name; id = $id; title = if ($PageTitle) { $PageTitle } else { $id }
				creator = ''; locale = ''; claimedLeague = ''; claimedPatch = $null
				claimedMainSkill = $null; sourceUrl = $PageUrl; creatorUrl = ''
				rightsStatus = 'unverified'; rightsEvidenceUrl = ''
				acquisitionMethod = 'manual_source_page_link'
				discoveryPageUrl = $PageUrl; discoveredBuildUrl = ('https://' + $provider.Host + $provider.Path + $id)
			})
		}
	}
	foreach ($match in [regex]::Matches($Html, '(?is)<a\b(?<attrs>[^>]*)>(?<text>.*?)</a\s*>')) {
		$hrefMatch = [regex]::Match($match.Groups['attrs'].Value, '(?is)\bhref\s*=\s*(?:"(?<q>[^"]*)"|''(?<s>[^'']*)''|(?<u>[^\s>]+))')
		if (-not $hrefMatch.Success) { continue }
		$href = if ($hrefMatch.Groups['q'].Success) { $hrefMatch.Groups['q'].Value } elseif ($hrefMatch.Groups['s'].Success) { $hrefMatch.Groups['s'].Value } else { $hrefMatch.Groups['u'].Value }
		$href = [Net.WebUtility]::HtmlDecode($href.Trim())
		try { $absolute = [Uri]::new([Uri]$PageUrl, $href).AbsoluteUri } catch { continue }
		$anchor = [Net.WebUtility]::HtmlDecode(($match.Groups['text'].Value -replace '(?is)<[^>]+>', ' ')).Trim()
		$canonical = ConvertTo-PoBImportUrl $absolute
		if ($canonical) { $links.Add([pscustomobject]@{ Url = $canonical; AnchorText = $anchor }) }
		foreach ($provider in $providerPatterns) {
			if ($absolute -match $provider.Pattern) {
				$id = $Matches['id']
				$candidates.Add([pscustomobject]@{
					providerId = $provider.Name; id = $id; title = if ($PageTitle) { $PageTitle } else { $id }
					creator = ''; locale = ''; claimedLeague = ''; claimedPatch = $null
					claimedMainSkill = $null; sourceUrl = $PageUrl; creatorUrl = ''
					rightsStatus = 'unverified'; rightsEvidenceUrl = ''
					acquisitionMethod = 'manual_source_page_link'
					discoveryPageUrl = $PageUrl; discoveredBuildUrl = ('https://' + $provider.Host + $provider.Path + $id)
				})
				break
			}
		}
	}
	$codeBlocks = [Collections.Generic.List[string]]::new()
	foreach ($block in [regex]::Matches($Html, '(?is)<(?:pre|textarea|code)\b[^>]*>(?<body>.*?)</(?:pre|textarea|code)\s*>')) {
		$codeBlocks.Add($block.Groups['body'].Value)
	}
	foreach ($attribute in [regex]::Matches($searchableHtml, '(?is)\bdata-(?:pob-code|pobcode|build-code|pob)\s*=\s*(?:"(?<q>[^"]+)"|''(?<s>[^'']+)''|(?<u>[^\s>]+))')) {
		$value = if ($attribute.Groups['q'].Success) { $attribute.Groups['q'].Value } elseif ($attribute.Groups['s'].Success) { $attribute.Groups['s'].Value } else { $attribute.Groups['u'].Value }
		$codeBlocks.Add($value)
	}
	foreach ($scriptBlock in [regex]::Matches($Html, '(?is)<script\b[^>]*>(?<body>.*?)</script\s*>')) {
		$body = $scriptBlock.Groups['body'].Value
		if ($body -match '(?i)pob|path\s+of\s+building|sharecode|buildcode') { $codeBlocks.Add($body) }
	}
	$visibleText = $Html -replace '(?is)<(?:script|style|svg)\b[^>]*>.*?</(?:script|style|svg)\s*>', ' '
	$visibleText = [Net.WebUtility]::HtmlDecode(($visibleText -replace '(?is)<[^>]+>', ' '))
	$inlineCodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($block in $codeBlocks) {
		$plain = [Net.WebUtility]::HtmlDecode(($block -replace '(?is)<[^>]+>', ' ')) -replace '\\[nrt]', '' -replace '\s+', ''
		foreach ($codeMatch in [regex]::Matches($plain, 'eN[A-Za-z0-9+/_-]{254,16777214}={0,2}')) {
			$null = $inlineCodes.Add($codeMatch.Value)
		}
	}
	foreach ($codeMatch in [regex]::Matches($visibleText, 'eN[A-Za-z0-9+/_-]{254,16777214}={0,2}')) { $null = $inlineCodes.Add($codeMatch.Value) }
	foreach ($code in $inlineCodes) {
		$hash = Get-PoBImportSha256 $code
		$candidates.Add([pscustomobject]@{
			providerId = 'ManualInlineCode'; id = 'manualinline-' + $hash.Substring(0, 56)
			title = if ($PageTitle) { $PageTitle } else { 'Build PoB encontrada em página pública' }
			creator = ''; locale = ''; claimedLeague = ''; claimedPatch = $null
			claimedMainSkill = $null; sourceUrl = $PageUrl; creatorUrl = ''
			rightsStatus = 'unverified'; rightsEvidenceUrl = ''
			acquisitionMethod = 'manual_selected_source_page_inline_code'
			discoveryPageUrl = $PageUrl; inlineCode = $code; inlineCodeSha256 = $hash
		})
	}
	$unique = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
	foreach ($candidate in $candidates) {
		$key = [string]$candidate.providerId + ':' + [string]$candidate.id
		if (-not $unique.ContainsKey($key)) { $unique[$key] = $candidate }
	}
	return [pscustomobject]@{ Candidates = @($unique.Values); Links = @($links) }
}

function Get-PoBImportReplacementTargetMatches([string]$Text, [object[]]$Targets) {
	$matches = [Collections.Generic.List[object]]::new()
	$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
	$decodedText = [Net.WebUtility]::HtmlDecode($Text)
	foreach ($target in $Targets) {
		$rejectionId = [string]$target.rejectionId
		$skillName = [string]$target.mainSkillName
		if (-not $rejectionId -or $skillName.Length -lt 3) { continue }
		$pattern = '(?i)(?<![\p{L}\p{N}])' + [regex]::Escape($skillName) + '(?![\p{L}\p{N}])'
		if ([regex]::IsMatch($decodedText, $pattern) -and $seen.Add($rejectionId)) {
			$matches.Add([pscustomobject]@{
				rejectionId = $rejectionId; patch = [string]$target.patch
				mainSkillKey = [string]$target.mainSkillKey; mainSkillName = $skillName
			})
		}
	}
	return @($matches)
}

function New-PoBImportSocketsHandler {
	if (-not ('PoBImportPublicConnector' -as [type])) {
		$connectorSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

public static class PoBImportPublicConnector
{
	public static async ValueTask<Stream> Connect(SocketsHttpConnectionContext context, CancellationToken cancellationToken)
	{
		if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
		var hostName = context.DnsEndPoint.Host;
		var port = context.DnsEndPoint.Port;
		var addresses = await Dns.GetHostAddressesAsync(hostName, cancellationToken).ConfigureAwait(false);
		if (addresses.Length == 0) throw new HttpRequestException("No address was returned for " + hostName);
		foreach (var address in addresses)
			if (!IsPublic(address)) throw new HttpRequestException("Connection refused because DNS resolved to a non-public address: " + hostName);
		Exception lastError = null;
		foreach (var address in addresses)
		{
			var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
			try
			{
				await socket.ConnectAsync(new IPEndPoint(address, port), cancellationToken).ConfigureAwait(false);
				return new NetworkStream(socket, ownsSocket: true);
			}
			catch (Exception error)
			{
				lastError = error;
				socket.Dispose();
				if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
			}
		}
		throw new HttpRequestException("Could not connect to a validated public address for " + hostName, lastError);
	}

	private static bool IsPublic(IPAddress address)
	{
		if (IPAddress.IsLoopback(address)) return false;
		var bytes = address.GetAddressBytes();
		if (address.AddressFamily == AddressFamily.InterNetwork)
		{
			var a = (int)bytes[0]; var b = (int)bytes[1];
			if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
			if (a == 100 && b >= 64 && b <= 127) return false;
			if (a == 169 && b == 254) return false;
			if (a == 172 && b >= 16 && b <= 31) return false;
			if (a == 192 && b == 168) return false;
			if (a == 198 && (b == 18 || b == 19)) return false;
			return true;
		}
		if (address.AddressFamily == AddressFamily.InterNetworkV6)
		{
			if (address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || address.IsIPv6Multicast) return false;
			if ((bytes[0] & 0xFE) == 0xFC) return false;
			if (address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.IPv6Loopback)) return false;
			if (address.IsIPv4MappedToIPv6) return IsPublic(address.MapToIPv4());
			return true;
		}
		return false;
	}
}
'@
		$null = Add-Type -TypeDefinition $connectorSource -Language CSharp -ErrorAction Stop
	}
	$handler = [System.Net.Http.SocketsHttpHandler]::new()
	$handler.AllowAutoRedirect = $false
	$delegateType = [Func[System.Net.Http.SocketsHttpConnectionContext, System.Threading.CancellationToken, System.Threading.Tasks.ValueTask[System.IO.Stream]]]
	$connectMethod = [PoBImportPublicConnector].GetMethod('Connect')
	$handler.ConnectCallback = [System.Delegate]::CreateDelegate($delegateType, $connectMethod)
	return $handler
}

function Invoke-PoBImportGet {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Url,
		[ValidateRange(1, 10485760)][int]$MaximumBytes = 2097152,
		[string]$Accept = 'text/html, application/xml, text/xml, text/plain;q=0.9, */*;q=0.1'
	)
	$canonical = ConvertTo-PoBImportUrl $Url
	if (-not $canonical) { throw 'Refusing a non-HTTPS or malformed import URL.' }
	$uri = [Uri]$canonical
	if (-not (Test-PoBImportPublicHost $uri.IdnHost)) { throw ('Refusing a non-public or unresolvable host: ' + $uri.IdnHost) }
	$handler = New-PoBImportSocketsHandler
	$client = [System.Net.Http.HttpClient]::new($handler)
	$client.Timeout = [TimeSpan]::FromSeconds(30)
	$client.DefaultRequestHeaders.UserAgent.ParseAdd('PoBManualBuildImporter/1.0')
	$client.DefaultRequestHeaders.Accept.ParseAdd($Accept)
	$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $canonical)
	$response = $null
	$timeoutSource = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
	try {
		# ResponseHeadersRead ends HttpClient's Timeout at the headers. Pass an
		# explicit token through body reads too, so a stalled provider cannot hang
		# the ingestion worker indefinitely after returning headers.
		$response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $timeoutSource.Token).GetAwaiter().GetResult()
		$status = [int]$response.StatusCode
		$contentType = if ($response.Content.Headers.ContentType) { [string]$response.Content.Headers.ContentType.MediaType } else { '' }
		$location = if ($response.Headers.Location) { [string]$response.Headers.Location } else { '' }
		$body = ''
		if ($response.Content -and $status -notin @(204, 301, 302, 303, 307, 308)) {
			$length = $response.Content.Headers.ContentLength
			if ($null -ne $length -and [long]$length -gt $MaximumBytes) { throw ('Response exceeded the configured byte limit: ' + $canonical) }
			$stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
			$memory = [IO.MemoryStream]::new()
			$buffer = [byte[]]::new(65536)
			try {
				while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length, $timeoutSource.Token).GetAwaiter().GetResult()) -gt 0) {
					if ($memory.Length + $read -gt $MaximumBytes) { throw ('Response exceeded the configured byte limit: ' + $canonical) }
					$memory.Write($buffer, 0, $read)
				}
				$encoding = [Text.Encoding]::UTF8
				if ($response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.CharSet) {
					try { $encoding = [Text.Encoding]::GetEncoding($response.Content.Headers.ContentType.CharSet.Trim('"')) } catch { }
				}
				$body = $encoding.GetString($memory.ToArray())
			} finally { $stream.Dispose(); $memory.Dispose() }
		}
		return [pscustomobject]@{ Url = $canonical; StatusCode = $status; ContentType = $contentType; Location = $location; Body = $body }
	} finally {
		if ($response) { $response.Dispose() }
		$request.Dispose(); $client.Dispose(); $handler.Dispose(); $timeoutSource.Dispose()
	}
}

Export-ModuleMember -Function Get-PoBImportSha256, ConvertTo-PoBImportUrl, Test-PoBImportPublicAddress, Test-PoBImportPublicHost, Get-PoBImportRobotsPolicy, Test-PoBImportRobotsPath, Get-PoBImportCandidatesFromHtml, Get-PoBImportReplacementTargetMatches, New-PoBImportSocketsHandler, Invoke-PoBImportGet
