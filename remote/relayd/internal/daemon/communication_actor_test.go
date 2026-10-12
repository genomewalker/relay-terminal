package daemon

import "testing"

func TestCommunicationCorrectsOnlyProvenDaemonBootstrapAlias(t *testing.T) {
	logical := "800c06ef-203f-4401-bf7a-c67b15985f33"
	bootstrap := "5a30d83a-5222-48f3-93c7-42fa687d901b"
	actor := CommunicationActor{Version: 1, PaneID: logical, Source: "native_parked_job_kernel_owner"}
	r := CommunicationRequest{Operation: "send", ActorPaneID: bootstrap, SourcePaneID: bootstrap,
		PaneID: "1652a003-70e9-4614-addb-68564fa8383b", MessageID: "fixture", ClientToken: "fixture-credential", Text: "fixture"}
	got, err := reconcileCommunicationActor(r, actor, bootstrap)
	if err != nil || got.ActorPaneID != logical || got.SourcePaneID != logical ||
		got.ClientToken != r.ClientToken || got.MessageID != r.MessageID || got.PaneID != r.PaneID || got.Text != r.Text {
		t.Fatal("logical pane correction changed the message or authorization", got, err)
	}
	for _, change := range []func(*CommunicationRequest, *CommunicationActor, *string){
		func(r *CommunicationRequest, a *CommunicationActor, b *string) {
			r.SourcePaneID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
		},
		func(r *CommunicationRequest, a *CommunicationActor, b *string) {
			r.ActorPaneID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
		},
		func(r *CommunicationRequest, a *CommunicationActor, b *string) {
			a.Source = "foreground_worker_kernel_ancestry"
		},
		func(r *CommunicationRequest, a *CommunicationActor, b *string) { *b = "" },
	} {
		request, proof, origin := r, actor, bootstrap
		change(&request, &proof, &origin)
		if _, err := reconcileCommunicationActor(request, proof, origin); err == nil {
			t.Fatal("unproven sender alias accepted")
		}
	}
}
