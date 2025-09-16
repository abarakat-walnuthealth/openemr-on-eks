# OpenEMR on EKS: BCBSMA EDI Integration Implementation Plan

**Date:** September 2025
**Project:** Walnut Health OpenEMR Deployment
**Purpose:** Enable BCBSMA EDI transaction processing in production AWS environment

## Executive Summary

This document outlines the critical gaps between our current AWS OpenEMR deployment and the requirements for BCBSMA EDI integration, along with a detailed implementation plan to resolve them.

**Current State:** We have a working OpenEMR deployment on AWS EKS, but it uses the standard OpenEMR Docker image which lacks our required BCBSMA EDI customizations.

**Critical Issue:** Local development environment contains working EDI customizations for BCBSMA 837P submission, but these modifications are not deployed to the AWS production environment.

**Goal:** Deploy custom OpenEMR code with BCBSMA EDI formatting to AWS and establish transport protocols for healthcare transaction processing.

## Current Architecture Analysis

### AWS Production Environment
- **Infrastructure:** EKS Auto Mode cluster with Aurora Serverless V2, Valkey cache, EFS storage
- **Application:** Standard `openemr/openemr:7.0.3` Docker image from Docker Hub
- **Status:** Fully operational infrastructure, lacking custom EDI functionality
- **Deployment:** Originally deployed from different repository instance (no Terraform state in current repo)

### Local Development Environment
- **Location:** `../openemr/` directory
- **Status:** Contains working BCBSMA EDI customizations
- **Testing:** Successfully generates 837P files, tested against sftp.staging.bluecrossma.com
- **Customizations:** Modified library/billing_utilities.php, interface/billing/, src/Services/

### Critical Gap
```
Local Development:           AWS Production:
├── Custom EDI logic         ├── Standard EDI logic
├── BCBSMA formatting        ├── Generic formatting
├── Tested 837P files        ├── Untested capabilities
└── Working submissions      └── No SFTP transport
```

## Identified Critical Issues

### 1. Code Deployment Gap
- **Issue:** AWS uses `openemr/openemr:7.0.3` from Docker Hub (standard image)
- **Impact:** Cannot generate properly formatted 837P files for BCBSMA
- **Evidence:** Local testing shows formatting differences that require custom code

### 2. Missing Transport Configuration
- **Issue:** No SFTP or HTTPS transport protocols configured
- **Impact:** Cannot submit/receive EDI files to/from BCBSMA
- **Requirements:**
  - SFTP endpoints: sftp.staging.bluecrossma.com, sftp.bluecrossma.com
  - HTTPS/Apigee integration for real-time 270/271 transactions

### 3. SSL Certificate Requirements
- **Issue:** No ACM certificate for walnuthealth.org domain
- **Impact:** Cannot establish HTTPS connectivity with BCBSMA Apigee gateway
- **Requirement:** Validated certificate for walnuthealth.org and *.walnuthealth.org

### 4. Network Connectivity
- **Issue:** AWS NAT Gateway IP addresses not whitelisted with BCBSMA
- **Impact:** Cannot establish outbound SFTP connections to BCBSMA endpoints
- **Action Required:** Coordinate with Tracy (BCBSMA EDI team) for IP whitelisting

### 5. Infrastructure State Management
- **Issue:** Terraform state not present in current repository
- **Impact:** Cannot safely modify infrastructure without risk of conflicts
- **Constraint:** Must work within existing deployed infrastructure

## BCBSMA Integration Requirements

### EDI Transaction Support Required
- **837P:** Professional Claims (primary billing transaction)
- **270/271:** Eligibility Inquiry/Response
- **276/277:** Claim Status Inquiry/Response
- **835:** Electronic Remittance Advice (payment processing)
- **999:** Functional Acknowledgments

### Format Corrections Identified
Based on local testing against BCBSMA staging:

1. **GS Segment Issues:**
   - Time format should be HHMMSSDD
   - Group control number should be 1

2. **BHT Segment Issues:**
   - BHT03 may need to be 9 characters long

3. **Loop1000A Issues:**
   - Should use V7BS instead of EIN (931416822) in NM109

4. **Address Formatting:**
   - Loop2000A missing "SUITE 6" from address (N302)
   - Loop2010BB missing "#1300" from payer address (N302)

5. **File Structure Issues:**
   - Missing tilde (~) segment separators
   - File should be single continuous line, not line-by-line format

### Transport Protocol Endpoints
- **SFTP Staging:** sftp.staging.bluecrossma.com
- **SFTP Production:** sftp.bluecrossma.com
- **HTTPS Gateway:** BCBSMA Apigee (requires walnuthealth.org certificate)

## Multi-Step Action Plan

### Phase 1: Custom Docker Image Implementation

**Priority:** CRITICAL - Must be completed first

#### TODO 1.1: Set Up Custom Image Infrastructure
- [ ] Create ECR (Elastic Container Registry) repository in AWS
- [ ] Configure repository permissions for EKS service account
- [ ] Set up local Docker build environment
- [ ] Verify AWS CLI and Docker login configuration

**Commands:**
```bash
# Create ECR repository
aws ecr create-repository --repository-name walnut-openemr --region us-west-2

# Get login token
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-west-2.amazonaws.com
```

#### TODO 1.2: Create Custom Docker Image Structure
- [ ] Create `custom-image/` directory in this repository
- [ ] Create `custom-image/Dockerfile` extending `openemr/openemr:7.0.3`
- [ ] Create `custom-image/customizations/` directory structure
- [ ] Create `custom-image/build.sh` script for automated builds

**Directory Structure:**
```
custom-image/
├── Dockerfile
├── build.sh
└── customizations/
    ├── library/
    ├── interface/billing/
    ├── src/Services/
    └── sql/
```

#### TODO 1.3: Copy Local Customizations
- [ ] Identify all modified files in `../openemr/` directory
- [ ] Copy modified PHP files to `custom-image/customizations/`
- [ ] Copy any custom SQL migrations or schema changes
- [ ] Verify file permissions and ownership requirements

**Files to Copy (minimum):**
- `library/billing_utilities.php` (EDI formatting logic)
- `interface/billing/*` (billing interface modifications)
- `src/Services/*` (any custom EDI services)
- Custom SQL files for BCBSMA partner configuration

#### TODO 1.4: Build and Test Custom Image
- [ ] Build custom Docker image locally
- [ ] Test image functionality with local Docker run
- [ ] Verify EDI functionality works in custom image
- [ ] Test database connectivity and file persistence

**Commands:**
```bash
cd custom-image/
docker build -t walnut-openemr:v1.0.0 .
docker run -p 8080:80 -e MYSQL_HOST=localhost walnut-openemr:v1.0.0
# Test EDI generation in running container
```

#### TODO 1.5: Deploy Custom Image to ECR
- [ ] Tag image with ECR repository URL
- [ ] Push custom image to ECR
- [ ] Verify image is available in AWS Console
- [ ] Configure image scanning and security policies

### Phase 2: Kubernetes Deployment Update

**Priority:** HIGH - Required for custom code deployment

#### TODO 2.1: Update Deployment Configuration
- [ ] Modify `k8s/deployment.yaml` to reference custom ECR image
- [ ] Update image pull policy and repository credentials
- [ ] Verify EKS service account has ECR pull permissions
- [ ] Test configuration with `kubectl diff` or dry-run

**Configuration Change:**
```yaml
# Change from:
image: openemr/openemr:${OPENEMR_VERSION}
# To:
image: <account-id>.dkr.ecr.us-west-2.amazonaws.com/walnut-openemr:v1.0.0
```

#### TODO 2.2: Deploy Updated Application
- [ ] Connect to EKS cluster: `aws eks update-kubeconfig`
- [ ] Apply updated deployment: `kubectl apply -f deployment.yaml`
- [ ] Monitor rollout: `kubectl rollout status deployment/openemr -n openemr`
- [ ] Verify pods are running with custom image
- [ ] Test application accessibility and basic functionality

#### TODO 2.3: Validate Custom Code Deployment
- [ ] Access running container: `kubectl exec -it <pod> -n openemr -- /bin/bash`
- [ ] Verify custom files are present in `/var/www/localhost/htdocs/openemr/`
- [ ] Test EDI generation functionality within running container
- [ ] Compare with local development environment behavior

### Phase 3: Transport Protocol Configuration

**Priority:** HIGH - Required for BCBSMA connectivity

#### TODO 3.1: SFTP Configuration
- [ ] Obtain SFTP credentials for both staging and production environments
- [ ] Create Kubernetes secrets for SFTP authentication
- [ ] Configure OpenEMR X12 Partners for BCBSMA endpoints
- [ ] Test SFTP connectivity from within EKS cluster

**Secret Creation:**
```bash
kubectl create secret generic bcbsma-sftp-credentials \
  --from-literal=staging-username="walnut-health-dev" \
  --from-literal=staging-password="<staging-password>" \
  --from-literal=prod-username="walnut-health-prod" \
  --from-literal=prod-password="<prod-password>" \
  -n openemr
```

#### TODO 3.2: SSL Certificate Setup
- [ ] Request ACM certificate for walnuthealth.org
- [ ] Complete DNS validation process
- [ ] Configure certificate ARN in ingress configuration
- [ ] Update load balancer to use validated certificate
- [ ] Test HTTPS connectivity

**ACM Certificate Request:**
```bash
aws acm request-certificate \
  --domain-name walnuthealth.org \
  --domain-name *.walnuthealth.org \
  --validation-method DNS \
  --region us-west-2
```

#### TODO 3.3: Network Configuration
- [ ] Identify current NAT Gateway IP addresses for EKS cluster
- [ ] Coordinate with Tracy (BCBSMA EDI team) for IP whitelisting
- [ ] Verify outbound connectivity to SFTP endpoints
- [ ] Configure security group rules if necessary

**IP Identification:**
```bash
# Find NAT Gateway IPs
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=<vpc-id>" --query 'NatGateways[*].NatGatewayAddresses[*].PublicIp'
```

### Phase 4: BCBSMA Integration Testing

**Priority:** MEDIUM - Validation and optimization

#### TODO 4.1: Staging Environment Testing
- [ ] Generate 837P file using custom AWS deployment
- [ ] Submit test file to sftp.staging.bluecrossma.com
- [ ] Monitor for 999/TA1 acknowledgment responses
- [ ] Analyze any formatting rejection messages
- [ ] Iterate on formatting fixes as needed

#### TODO 4.2: Format Validation and Correction
- [ ] Implement specific BCBSMA formatting requirements
- [ ] Test tilde separator addition to segment endings
- [ ] Verify single-line file format output
- [ ] Validate address field completeness (SUITE 6, #1300)
- [ ] Test V7BS submitter ID usage

#### TODO 4.3: Response Processing Setup
- [ ] Configure EDI response file reception
- [ ] Test 835 (remittance) file processing and payment posting
- [ ] Verify 271 (eligibility response) parsing
- [ ] Set up monitoring for failed transaction processing
- [ ] Configure alerts for EDI processing errors

#### TODO 4.4: Production Validation
- [ ] Complete all staging tests successfully
- [ ] Coordinate production cutover with BCBSMA
- [ ] Submit initial production 837P files
- [ ] Monitor transaction processing and response times
- [ ] Establish ongoing monitoring and maintenance procedures

### Phase 5: Monitoring and Maintenance

**Priority:** MEDIUM - Operational sustainability

#### TODO 5.1: Observability Setup
- [ ] Configure CloudWatch dashboards for EDI transaction metrics
- [ ] Set up alerts for failed SFTP transmissions
- [ ] Monitor custom Docker image security vulnerabilities
- [ ] Establish log aggregation for EDI processing events

#### TODO 5.2: Backup and Recovery
- [ ] Ensure EDI files are included in existing backup strategy
- [ ] Test recovery procedures for custom Docker image
- [ ] Document rollback process for deployment issues
- [ ] Verify database backup includes EDI configuration data

#### TODO 5.3: Update and Maintenance Procedures
- [ ] Document custom image build and deployment process
- [ ] Establish version control for custom code changes
- [ ] Create testing procedures for future OpenEMR version upgrades
- [ ] Plan for ongoing BCBSMA requirement changes and updates

## Technical Implementation Details

### Docker Image Build Process
```dockerfile
FROM openemr/openemr:7.0.3

# Copy custom EDI modifications
COPY ./customizations/library/ /var/www/localhost/htdocs/openemr/library/
COPY ./customizations/interface/ /var/www/localhost/htdocs/openemr/interface/
COPY ./customizations/src/ /var/www/localhost/htdocs/openemr/src/

# Set proper permissions
RUN chown -R apache:root /var/www/localhost/htdocs/openemr/ && \
    chmod -R 755 /var/www/localhost/htdocs/openemr/

# Rebuild autoloader for custom classes
RUN composer dump-autoload -o

LABEL maintainer="Walnut Health" \
      version="7.0.3-walnut-v1.0.0"
```

### Kubernetes Configuration Updates
```yaml
# Update in k8s/deployment.yaml
spec:
  template:
    spec:
      containers:
      - name: openemr
        image: <account-id>.dkr.ecr.us-west-2.amazonaws.com/walnut-openemr:v1.0.0
        imagePullPolicy: Always
```

### AWS Resources Required
- **ECR Repository:** `walnut-openemr`
- **ACM Certificate:** `walnuthealth.org` and `*.walnuthealth.org`
- **Kubernetes Secrets:** SFTP credentials
- **Security Group Rules:** Outbound SFTP access (port 22)

## Risk Assessment and Mitigation

### High Risk Items
1. **Custom Image Breaks Application**
   - **Mitigation:** Thorough local testing before deployment
   - **Rollback:** Keep original deployment.yaml for quick revert

2. **BCBSMA Connectivity Issues**
   - **Mitigation:** Test all connectivity from within EKS cluster
   - **Escalation:** Direct coordination with Tracy for troubleshooting

3. **Infrastructure Modification Conflicts**
   - **Mitigation:** Work within existing Kubernetes deployments only
   - **Constraint:** Avoid Terraform changes due to missing state

### Medium Risk Items
1. **EDI Format Compatibility**
   - **Mitigation:** Extensive staging environment testing
   - **Validation:** Compare with known good 837P files

2. **Performance Impact of Custom Image**
   - **Mitigation:** Monitor application performance metrics
   - **Optimization:** Use multi-stage builds to minimize image size

## Dependencies and Coordination

### External Dependencies
- **Tracy (BCBSMA EDI Team):** IP whitelisting, credential provisioning
- **DNS Provider:** Certificate validation for walnuthealth.org
- **Local Development Environment:** Source of custom code modifications

### Internal Dependencies
- **AWS Access:** ECR repository creation and management
- **Kubernetes Access:** Deployment updates and secret management
- **Local Docker Environment:** Image building and testing

## Success Criteria

1. **Custom code successfully deployed to AWS production environment**
2. **837P files generate with BCBSMA-compliant formatting**
3. **Successful SFTP transmission to staging environment**
4. **999/TA1 acknowledgments received without format errors**
5. **HTTPS connectivity established for 270/271 transactions**
6. **Production 837P submission accepted by BCBSMA**

## Estimated Timeline

- **Phase 1 (Custom Image):** 3-5 days
- **Phase 2 (Deployment):** 1-2 days
- **Phase 3 (Transport):** 2-3 days
- **Phase 4 (Testing):** 5-7 days
- **Phase 5 (Monitoring):** 2-3 days

**Total Estimated Duration:** 2-3 weeks

## Next Steps

1. **Immediate:** Begin Phase 1 (Custom Docker Image Implementation)
2. **Coordinate:** Contact Tracy for IP whitelisting requirements
3. **Prepare:** Gather all SFTP credentials and access requirements
4. **Validate:** Test custom image locally before AWS deployment

---

**Document Status:** Ready for Implementation
**Last Updated:** September 2025
**Contact:** Available for clarification and technical guidance during implementation