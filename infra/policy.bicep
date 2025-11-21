targetScope = 'resourceGroup'

@description('デモ環境で適用するポリシー イニシアチブ割り当ての一覧')
param policyAssignments array

@description('Managed Identity のロケーション（LOCATION 環境変数から渡される）')
param managedIdentityLocation string

module initiativeAssignments 'modules/policyAssignment.bicep' = [for (assignment, i) in policyAssignments: {
  name: 'policyAssignment-${i}'
  scope: resourceGroup()
  params: {
    policySetDefinitionId: assignment.policySetDefinitionId
    assignmentName: assignment.assignmentName
    displayName: assignment.displayName
    assignmentDescription: assignment.assignmentDescription
    nonComplianceMessage: assignment.nonComplianceMessage
    policyParameters: assignment.policyParameters
    policyOverrides: assignment.policyOverrides
    enableManagedIdentity: assignment.enableManagedIdentity
    managedIdentityLocation: managedIdentityLocation
  }
}]

output assignmentIds array = [for (assignment, i) in policyAssignments: initiativeAssignments[i].outputs.policyAssignmentId]
