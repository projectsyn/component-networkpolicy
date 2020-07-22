local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.networkpolicy;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('networkpolicy', 'syn', secrets=false);

{
  networkpolicy: app,
}
