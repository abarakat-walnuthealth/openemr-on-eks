# Enhanced AWS ACM Certificate Setup & OpenEMR 270/271 Integration for BCBSMA

## Understanding OpenEMR 270/271 Functionality
### Current OpenEMR Eligibility Features
- **Location**: Reports → Eligibility → "Eligibility 270 Inquiry Batch"
- **Purpose**: Batch insurance eligibility verification for multiple patients
- **File Processing**: Generates X12 270 files, receives and parses 271 responses
- **Response Viewing**: Patient Demographics → Insurance tab → Eligibility response section

### BCBSMA Specific Requirements
- **Transport**: HTTPS via Apigee gateway (NOT SFTP like 837P)
- **Real-time**: Synchronous request/response (not batch file transfer)
- **Certificate**: TLS/Public certificate required for domain authentication
- **Format**: Standard X12 270/271 EDI format

---

## Phase 1: Domain Prerequisites Check
1. **Verify domain ownership**
   ```bash
   nslookup walnuthealth.org
   whois walnuthealth.org
   ```

2. **Check current DNS provider**
   - Determine if using Route53 or external provider
   - Note current nameservers for domain

3. **List existing ACM certificates**
   ```bash
   aws acm list-certificates --region us-east-1
   ```

---

## Phase 2: Request ACM Certificate
1. **Request public certificate**
   ```bash
   aws acm request-certificate \
     --domain-name walnuthealth.org \
     --subject-alternative-names "*.walnuthealth.org" "edi.walnuthealth.org" "api.walnuthealth.org" \
     --validation-method DNS \
     --region us-east-1
   ```

2. **Note certificate ARN**
   - Save the returned CertificateArn for later use

---

## Phase 3: Domain Validation
1. **Get CNAME validation records**
   ```bash
   aws acm describe-certificate \
     --certificate-arn <YOUR_CERT_ARN> \
     --region us-east-1 \
     --query "Certificate.DomainValidationOptions"
   ```

2. **Add CNAME records to DNS**
   - **If Route53**: Use AWS Console to auto-create records
   - **If external**: Manually add CNAME records to DNS provider

3. **Wait for validation**
   ```bash
   aws acm wait certificate-validated \
     --certificate-arn <YOUR_CERT_ARN> \
     --region us-east-1
   ```

---

## Phase 4: Configure EKS/OpenEMR Integration
1. **Update Kubernetes Ingress (k8s/ingress.yaml)**
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: openemr-ingress
     annotations:
       kubernetes.io/ingress.class: "alb"
       alb.ingress.kubernetes.io/scheme: internet-facing
       alb.ingress.kubernetes.io/certificate-arn: <YOUR_CERT_ARN>
       alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}, {"HTTP":80}]'
       alb.ingress.kubernetes.io/ssl-redirect: '443'
   spec:
     rules:
     - host: walnuthealth.org
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: openemr-service
               port:
                 number: 80
     - host: edi.walnuthealth.org
       http:
         paths:
         - path: /edi/270
           pathType: Prefix
           backend:
             service:
               name: openemr-service
               port:
                 number: 80
   ```

2. **Apply ingress changes**
   ```bash
   kubectl apply -f k8s/ingress.yaml
   ```

---

## Phase 5: OpenEMR 270/271 Configuration
1. **Configure BCBSMA as X12 Partner**
   - Navigate to: Admin → Practice → X12 Partners
   - Add new partner with:
     ```
     Partner Name: BCBSMA
     Receiver ID Qualifier (ISA07): ZZ
     Receiver ID (ISA08): BCBSMA
     Sender ID Qualifier (ISA05): ZZ
     Sender ID (ISA06): V7BS
     Version: 005010X279A1
     Eligibility Endpoint: https://api.bcbsma.com/eligibility
     Token Endpoint: https://api.bcbsma.com/auth/token
     Client ID: [Provided by BCBSMA]
     Client Secret: [Provided by BCBSMA]
     ```

2. **Enable eligibility checking in globals**
   - Admin → Globals → Connectors
   - Enable "Enable Eligibility Requests"
   - Set "Default X12 Partner" to BCBSMA

---

## Phase 6: Certificate Export for BCBSMA
1. **Export public certificate**
   ```bash
   aws acm export-certificate \
     --certificate-arn <YOUR_CERT_ARN> \
     --region us-east-1 \
     --output text > walnuthealth_public_cert.pem
   ```

2. **Send to BCBSMA**
   - Email certificate to tracy.ferullo@bcbsma.com
   - Include domain: walnuthealth.org
   - Request Apigee gateway configuration

---

## Phase 7: Detailed Testing Steps

### 7.1 Certificate Validation Testing
1. **Test HTTPS access**
   ```bash
   curl -I https://walnuthealth.org
   curl -I https://edi.walnuthealth.org
   ```

2. **Check SSL certificate**
   ```bash
   openssl s_client -connect walnuthealth.org:443 -servername walnuthealth.org
   ```

3. **SSL Labs test**
   - Visit: https://www.ssllabs.com/ssltest/
   - Test walnuthealth.org

### 7.2 OpenEMR 270 Generation Testing
1. **Create test patient with BCBSMA insurance**
   - Patient Demographics → Insurance → Add
   - Insurance Company: BCBSMA
   - Member ID: TEST123456
   - Group Number: TEST001

2. **Generate single 270 request**
   - Open patient chart
   - Click Insurance tab
   - Click "Check Eligibility" button
   - Verify 270 file generated in:
     ```bash
     kubectl exec <openemr-pod> -- ls -la /var/www/localhost/htdocs/openemr/sites/default/documents/edi/
     ```

3. **Check 270 file format**
   ```bash
   kubectl exec <openemr-pod> -- cat /var/www/localhost/htdocs/openemr/sites/default/documents/edi/<latest-270-file>
   ```
   - Verify ISA segment has BCBSMA identifiers
   - Check HL segments for proper hierarchy
   - Confirm NM1 segments have patient info

### 7.3 Batch Eligibility Testing
1. **Access batch eligibility**
   - Reports → Eligibility → "Eligibility 270 Inquiry Batch"
   - Select date range with scheduled patients
   - Choose X12 Partner: BCBSMA
   - Click "Create batch inquiry"

2. **Monitor file generation**
   - Check for batch 270 file in EDI directory
   - Verify multiple patient segments in single file

### 7.4 HTTPS Transmission Testing
1. **Test connectivity to BCBSMA Apigee**
   ```bash
   kubectl exec <openemr-pod> -- curl -I https://api.bcbsma.com/eligibility
   ```

2. **Send test 270 manually**
   ```bash
   kubectl exec <openemr-pod> -- curl -X POST \
     -H "Content-Type: application/x12" \
     -H "Authorization: Bearer <token>" \
     --cert /path/to/cert.pem \
     --data-binary @/path/to/270-file.txt \
     https://api.bcbsma.com/eligibility
   ```

3. **Verify 271 response**
   - Check HTTP status code (should be 200)
   - Verify 271 response format
   - Confirm eligibility data returned

### 7.5 271 Response Processing Testing
1. **Import 271 response**
   - Reports → EDI History
   - Upload 271 file
   - Process responses

2. **Verify eligibility display**
   - Patient Demographics → Insurance tab
   - Check "Last Eligibility Check" date
   - Verify coverage details displayed:
     - Active/Inactive status
     - Copay amounts
     - Deductible information
     - Coverage dates

### 7.6 End-to-End Workflow Testing
1. **Full eligibility check workflow**
   - Schedule appointment for test patient
   - Run batch eligibility for that date
   - Verify 270 generation
   - Confirm HTTPS transmission
   - Process 271 response
   - Check patient eligibility status updated

2. **Error handling tests**
   - Invalid member ID
   - Expired coverage
   - Network connectivity issues
   - Certificate validation failures

---

## Phase 8: Production Cutover
1. **Staging validation with BCBSMA**
   - Complete test transactions on staging.api.bcbsma.com
   - Verify with Tracy that transactions are received
   - Confirm 271 responses are valid

2. **Production configuration**
   - Update endpoint to production URL
   - Update credentials to production values
   - Test with real patient (with consent)

3. **Monitoring setup**
   - CloudWatch alarms for failed transactions
   - Daily eligibility check reports
   - Certificate expiration monitoring (though auto-renewed)

---

## Expected Outcomes
- ✅ ACM certificate issued and auto-renewing for walnuthealth.org
- ✅ HTTPS endpoint configured for 270/271 transactions
- ✅ OpenEMR successfully sending 270 requests via Apigee
- ✅ 271 responses received and parsed correctly
- ✅ Patient eligibility automatically updated in OpenEMR
- ✅ Certificate provided to BCBSMA and validated

## Success Criteria
- [ ] Certificate shows "Issued" status in ACM
- [ ] HTTPS works on walnuthealth.org and edi.walnuthealth.org
- [ ] BCBSMA confirms certificate acceptance
- [ ] Test 270 transaction succeeds
- [ ] Test 271 response properly parsed
- [ ] Batch eligibility produces valid files
- [ ] Production transaction completes successfully