# Signing a release

Signing is optional. Without signing arguments, `Build-Release.ps1` produces the unsigned release used today. Signing runs after obfuscation, then Inno signs setup and its uninstaller.

Use a certificate already in the Windows certificate store or a hardware token:

```powershell
$env:ROO_INDUSTRIES_SIGN_ARGS_JSON = '["/fd","SHA256","/tr","<RFC3161 TSA>","/td","SHA256","/sha1","<thumbprint>"]'
$env:ROO_INDUSTRIES_SIGN_SUBJECT = '<exact certificate subject>'
& tools\scripts\Build-Release.ps1
```

For Azure Trusted Signing, use `/fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib <Azure.CodeSigning.Dlib.dll> /dmdf <metadata.json>` in that JSON array. Follow [Microsoft’s signing setup](https://learn.microsoft.com/en-us/azure/trusted-signing/how-to-signing-integrations) for the dlib and metadata.

`-SignArguments`, `-SignSubject` and `-SignToolPath` may be passed directly. `ROO_INDUSTRIES_SIGNTOOL` selects an explicit signtool path; otherwise the newest Windows SDK x64 signtool is used. The subject must match exactly, and every Roo-built PE and the setup executable must pass signature verification. Arguments are not printed. Password switches are refused; keep private keys in the certificate store, token or signing service.

`-AllowUntrustedSignature` or `ROO_INDUSTRIES_SIGN_ALLOW_UNTRUSTED=1` permits `UnknownError`/`NotTrusted` for a local test certificate. Production certificates must verify as `Valid`. This option does not add a certificate to any trust store.
