local esp = import 'espejote.libsonnet';
local config = import 'lib/espejote-networkpolicy-sync/config.json';

// Common annotations and labels
local commonAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};
local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejote',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

// Extract the active policy sets from the given namespace object,
// based on the annotations applied by this ManagedResource.
local activePolicySets(namespace) =
  local set = std.get(std.get(namespace.metadata, 'annotations', {}), config.annotations.activePolicySets, '');
  if set == '' then
    []
  else
    std.set(std.map(std.trim, std.split(set, ',')));

// Extract the desired policy sets from the given namespace object,
// based on the labels and desired default behaviour (isolation by default).
// Returns an array of policy set names with zero or more entries.
local desiredPolicySets(namespace) =
  local objHasLabel(obj, label) =
    std.objectHas(std.get(obj.metadata, 'labels', {}), label);

  local defaultPolicySets =
    // Add default policy set 'namespace-isolation-full' if the namespace
    // has the label params.labels.baseDefaults set.
    if objHasLabel(namespace, config.labels.purgeNonBase) || objHasLabel(namespace, config.labels.baseDefaults) then
      [ config.setNamespaceIsolationFull ]
    // Add no default policy set if the namespace
    // has the label params.labels.purgeDefaults or params.labels.noDefaults set.
    else if objHasLabel(namespace, config.labels.purgeDefaults) || objHasLabel(namespace, config.labels.noDefaults) then
      []
    // Add default policy set 'namespace-isolation' if the namespace
    // does not have the label params.labels.purgeDefaults or params.labels.noDefaults set.
    else
      [ config.setNamespaceIsolationBasic ]
  ;

  // Policy sets based on the label params.labels.policySets.
  // Filters out the default policy sets, as they should not be added by the policy sets label.
  // An empty (null, '') label value results in an empty array.
  local policySetsFromLabel =
    local sets =
      std.get(std.get(namespace.metadata, 'labels', {}), config.labels.policySets, '');
    if sets == '' then
      []
    else
      std.filter(
        function(set) set != config.setNamespaceIsolationBasic && set != config.setNamespaceIsolationFull,
        std.map(std.trim, std.split(sets, ','))
      );

  // Return empty array if the namespace is ignored.
  // TODO: we should probably prune the active policy sets in namespaces that are ignored...
  // Maybe even annotate ignored namespaces with 'none'.
  if std.member(config.ignoredNamespaces, namespace.metadata.name) then
    []
  else
    std.set(policySetsFromLabel + defaultPolicySets)
;

// Extract the policy sets that should be deleted in that namespace,
// by subtracting the desired policy sets from the active policy sets.
local removedPolicySets(namespace) =
  std.setDiff(activePolicySets(namespace), desiredPolicySets(namespace));

local isCiliumPolicy(policyName) =
  std.startsWith(policyName, 'cilium/');

local shouldRenderPolicy(policyName) =
  if isCiliumPolicy(policyName) then
    config.hasCilium
  else
    true;

// Generate policy sets.
local generatePolicyMetadata(policyName, namespace) =
  (if isCiliumPolicy(policyName) then {
     apiVersion: 'cilium.io/v2',
     kind: 'CiliumNetworkPolicy',
     metadata+: {
       name: std.strReplace(policyName, 'cilium/', ''),
     },
   } else {
     apiVersion: 'networking.k8s.io/v1',
     kind: 'NetworkPolicy',
     metadata: {
       name: policyName,
     },
   }) + {
    metadata+: {
      annotations: commonAnnotations,
      labels: commonItemLabels,
      namespace: namespace.metadata.name,
    },
  };

local generatePolicySet(set, namespace) = std.filter(
  function(it) it != null,
  [
    generatePolicyMetadata(policyName, namespace) {
      spec: config.policies[policyName],
    }
    for policyName in config.policySets[set]
    if std.objectHas(config.policies, policyName) && shouldRenderPolicy(policyName)
  ]
);

local purgePolicySet(set, namespace) = std.filter(
  function(it) it != null,
  [
    esp.markForDelete(generatePolicyMetadata(policyName, namespace))
    for policyName in config.policySets[set]
    if std.objectHas(config.policies, policyName) && shouldRenderPolicy(policyName)
  ]
);
local generateNamespaceAnnotation(namespace) = [ {
  apiVersion: 'v1',
  kind: 'Namespace',
  metadata: {
    annotations: {
      [config.annotations.activePolicySets]: std.join(',', desiredPolicySets(namespace)),
    },
    name: namespace.metadata.name,
  },
} ];

// Reconcile the given namespace.
local reconcileNamespace(namespace) =
  // Generate array of NetworkPolicies for the given policy set.
  std.flattenArrays([
    generatePolicySet(set, namespace)
    for set in desiredPolicySets(namespace)
    if std.objectHas(config.policySets, set)
  ])
  // Generate array of NetworkPolicies to be deleted for the given policy set.
  + std.flattenArrays([
    purgePolicySet(set, namespace)
    for set in removedPolicySets(namespace)
    if std.objectHas(config.policySets, set)
  ])
  // Generate annotation for the given namespace containing the new active policy sets.
  + generateNamespaceAnnotation(namespace);

// check if the object is getting deleted by checking if it has
// `metadata.deletionTimestamp`.
local inDelete(obj) = std.get(obj.metadata, 'deletionTimestamp', '') != '';

// Do the thing
if esp.triggerName() == 'namespace' then (
  // Handle single namespace update on namespace trigger
  local nsTrigger = esp.triggerData();
  // nsTrigger.resource can be null if we're called when the namespace is getting
  // deleted. If it's not null, we still don't want to do anything when the
  // namespace is getting deleted.
  if nsTrigger.resource != null && !inDelete(nsTrigger.resource) then
    reconcileNamespace(nsTrigger.resource)
) else if esp.triggerName() == 'netpol' || esp.triggerName() == 'ciliumnetpol' then (
  // Handle single namespace update on netpol or ciliumnetpol trigger
  local namespace = esp.triggerData().resourceEvent.namespace;
  std.flattenArrays([
    reconcileNamespace(ns)
    for ns in esp.context().namespaces
    if ns.metadata.name == namespace && !inDelete(ns)
  ])
) else (
  // Reconcile all namespaces for jsonnetlibrary update or managedresource
  // reconcile.
  local namespaces = esp.context().namespaces;
  std.flattenArrays([
    reconcileNamespace(ns)
    for ns in namespaces
    if !inDelete(ns)
  ])
)
