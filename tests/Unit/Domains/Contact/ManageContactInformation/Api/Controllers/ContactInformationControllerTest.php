<?php

namespace Tests\Unit\Domains\Contact\ManageContactInformation\Api\Controllers;

use App\Models\Contact;
use App\Models\ContactInformation;
use App\Models\ContactInformationType;
use App\Models\Vault;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactInformationControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_creates_a_contact_information(): void
    {
        $user = $this->createUser(['read', 'write']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $vault = $this->setPermissionInVault($user, Vault::PERMISSION_EDIT, $vault);

        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $type = ContactInformationType::factory()->create([
            'account_id' => $user->account_id,
            'type' => 'email',
        ]);

        $response = $this->post(
            '/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/contactInformation',
            [
                'contact_information_type_id' => $type->id,
                'data' => 'jim@dundermifflin.com',
            ]
        );

        $response->assertStatus(201);
        $response->assertJsonPath('data.content', 'jim@dundermifflin.com');

        $this->assertDatabaseHas('contact_information', [
            'contact_id' => $contact->id,
            'data' => 'jim@dundermifflin.com',
        ]);
    }

    /** @test */
    public function it_destroys_a_contact_information(): void
    {
        $user = $this->createUser(['read', 'write']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $vault = $this->setPermissionInVault($user, Vault::PERMISSION_EDIT, $vault);

        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);
        $type = ContactInformationType::factory()->create([
            'account_id' => $user->account_id,
            'type' => 'email',
        ]);
        $information = ContactInformation::factory()->create([
            'contact_id' => $contact->id,
            'type_id' => $type->id,
        ]);

        $response = $this->delete(
            '/api/vaults/'.$vault->id.'/contacts/'.$contact->id.'/contactInformation/'.$information->id
        );

        $response->assertStatus(200);

        $this->assertDatabaseMissing('contact_information', [
            'id' => $information->id,
        ]);
    }
}
