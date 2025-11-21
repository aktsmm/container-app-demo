targetScope = 'resourceGroup'

@description('割り当て対象のポリシー イニシアチブ ID (/providers/Microsoft.Authorization/policySetDefinitions/<id>)')
param policySetDefinitionId string

@description('ポリシー割り当てのリソース名 (サブスクリプション内で一意)')
param assignmentName string

@description('ポリシー割り当ての表示名')
param displayName string

@description('ポリシー割り当ての説明')
param assignmentDescription string = ''

@description('コンプライアンス違反時に表示するメッセージ')
param nonComplianceMessage string = 'Review compliance results for this policy assignment.'

@description('イニシアチブに渡すパラメーター。不要な場合は空オブジェクトのまま。')
param policyParameters object = {}

@description('特定ポリシーの効果を上書きする設定。除外が必要な場合のみ指定。')
param policyOverrides array = []

@description('Modify/DeployIfNotExists を含む場合は true にしてマネージドIDを付与する')
param enableManagedIdentity bool = false

@description('enableManagedIdentity = true の場合に使用するリージョン名')
param managedIdentityLocation string = ''

// デモ環境全体へ共通ガードレールを適用するための汎用ポリシー割り当て
resource initiativeAssignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: assignmentName
  scope: resourceGroup()
  location: enableManagedIdentity ? managedIdentityLocation : null
  identity: enableManagedIdentity ? {
    type: 'SystemAssigned'
  } : null
  properties: {
    displayName: displayName
    description: assignmentDescription
    policyDefinitionId: policySetDefinitionId
    nonComplianceMessages: [
      {
        message: nonComplianceMessage
      }
    ]
    parameters: policyParameters
    overrides: length(policyOverrides) == 0 ? null : policyOverrides
    enforcementMode: 'Default'
  }
}

output policyAssignmentId string = initiativeAssignment.id
