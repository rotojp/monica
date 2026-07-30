<?php

namespace App\Domains\Contact\ManageContactInformation\Api\Controllers;

use App\Domains\Contact\ManageContactInformation\Services\CreateContactInformation;
use App\Domains\Contact\ManageContactInformation\Services\DestroyContactInformation;
use App\Http\Controllers\ApiController;
use App\Http\Resources\ContactInformationResource;
use App\Models\ContactInformation;
use Illuminate\Http\Request;
use Knuckles\Scribe\Attributes\{BodyParam,Response,ResponseFromApiResource};

/**
 * @group Contact management
 *
 * @subgroup Contact information
 */
class ContactInformationController extends ApiController
{
    public function __construct()
    {
        $this->middleware('abilities:write')->only(['store', 'destroy']);

        parent::__construct();
    }

    /**
     * Create a contact information.
     *
     * Adds a piece of contact information (email address, phone number, …)
     * to the given contact.
     */
    #[BodyParam('contact_information_type_id', description: 'The identifier of the contact information type.')]
    #[BodyParam('data', description: 'The content of the contact information. Max 255 characters.')]
    #[BodyParam('kind', description: 'The kind of the entry (e.g. personal, work).', required: false)]
    #[ResponseFromApiResource(ContactInformationResource::class, ContactInformation::class, status: 201)]
    public function store(Request $request, string $vaultId, string $contactId)
    {
        $information = (new CreateContactInformation)->execute([
            'account_id' => $request->user()->account_id,
            'author_id' => $request->user()->id,
            'vault_id' => $vaultId,
            'contact_id' => $contactId,
            'contact_information_type_id' => $request->integer('contact_information_type_id'),
            'contact_information_kind' => $request->input('kind'),
            'data' => $request->input('data'),
        ]);

        return new ContactInformationResource($information->load('contactInformationType'));
    }

    /**
     * Delete a contact information.
     *
     * Removes a piece of contact information from the given contact.
     */
    #[Response(['deleted' => true, 'id' => 1])]
    public function destroy(Request $request, string $vaultId, string $contactId, int $informationId)
    {
        (new DestroyContactInformation)->execute([
            'account_id' => $request->user()->account_id,
            'author_id' => $request->user()->id,
            'vault_id' => $vaultId,
            'contact_id' => $contactId,
            'contact_information_id' => $informationId,
        ]);

        return $this->respondObjectDeleted($informationId);
    }
}
