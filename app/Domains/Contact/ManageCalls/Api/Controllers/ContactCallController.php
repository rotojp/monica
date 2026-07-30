<?php

namespace App\Domains\Contact\ManageCalls\Api\Controllers;

use App\Domains\Contact\ManageCalls\Services\CreateCall;
use App\Http\Controllers\ApiController;
use App\Http\Resources\CallResource;
use App\Models\Call;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\{BodyParam,QueryParam,ResponseFromApiResource};

/**
 * @group Contact management
 *
 * @subgroup Calls
 */
class ContactCallController extends ApiController
{
    public function __construct()
    {
        $this->middleware('abilities:read')->only(['index']);
        $this->middleware('abilities:write')->only(['store']);

        parent::__construct();
    }

    /**
     * List all calls of a contact.
     *
     * Get all the calls logged with the given contact.
     */
    #[QueryParam('limit', 'int', description: 'A limit on the number of objects to be returned. Limit can range between 1 and 100, and the default is 10.', required: false, example: 10)]
    #[ResponseFromApiResource(CallResource::class, Call::class, collection: true)]
    public function index(Request $request, string $vaultId, string $contactId)
    {
        $vault = $request->user()->account->vaults()
            ->findOrFail($vaultId);

        $contact = $vault->contacts()->findOrFail($contactId);

        $calls = $contact->calls()
            ->orderBy('called_at', 'desc')
            ->paginate($this->getLimitPerPage());

        return CallResource::collection($calls);
    }

    /**
     * Log a call.
     *
     * Creates a call log entry for the given contact.
     */
    #[BodyParam('called_at', description: 'The date the call happened, in the Y-m-d format.')]
    #[BodyParam('description', description: 'What the call was about. Max 65535 characters.', required: false)]
    #[BodyParam('type', description: 'The type of the call: audio or video. Defaults to audio.', required: false)]
    #[BodyParam('who_initiated', description: 'Who made the call: me or contact. Defaults to me.', required: false)]
    #[ResponseFromApiResource(CallResource::class, Call::class, status: 201)]
    public function store(Request $request, string $vaultId, string $contactId)
    {
        $call = (new CreateCall)->execute([
            'account_id' => $request->user()->account_id,
            'author_id' => $request->user()->id,
            'vault_id' => $vaultId,
            'contact_id' => $contactId,
            'called_at' => $request->input('called_at'),
            'description' => $request->input('description'),
            'type' => $request->input('type', Call::TYPE_AUDIO),
            'answered' => true,
            'who_initiated' => $request->input('who_initiated', 'me'),
        ]);

        return new CallResource($call);
    }
}
