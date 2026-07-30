<?php

namespace Tests\Unit\Domains\Contact\ManageContact\Api\Controllers;

use App\Models\Contact;
use App\Models\ContactInformation;
use App\Models\Vault;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Tests\ApiTestCase;

class ContactControllerTest extends ApiTestCase
{
    use DatabaseTransactions;

    /** @test */
    public function it_gets_a_list_of_contacts(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
            'first_name' => 'Jim',
            'last_name' => 'Halpert',
        ]);
        ContactInformation::factory()->create([
            'contact_id' => $contact->id,
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts');

        $response->assertStatus(200);
        $response->assertJsonCount(1, 'data');
        $response->assertJsonPath('data.0.id', $contact->id);
        $response->assertJsonPath('data.0.first_name', 'Jim');
        $response->assertJsonPath('data.0.last_name', 'Halpert');
        $response->assertJsonCount(1, 'data.0.contact_information');
    }

    /** @test */
    public function it_does_not_list_archived_contacts(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        Contact::factory()->create([
            'vault_id' => $vault->id,
            'listed' => false,
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts');

        $response->assertStatus(200);
        $response->assertJsonCount(0, 'data');
    }

    /** @test */
    public function it_gets_a_contact(): void
    {
        $user = $this->createUser(['read']);

        $vault = Vault::factory()->create([
            'account_id' => $user->account_id,
        ]);
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
            'first_name' => 'Jim',
            'last_name' => 'Halpert',
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts/'.$contact->id);

        $response->assertStatus(200);
        $response->assertJsonPath('data.id', $contact->id);
        $response->assertJsonPath('data.first_name', 'Jim');
        $response->assertJsonPath('data.vault_id', $vault->id);
    }

    /** @test */
    public function it_gets_an_exception_getting_a_contact_in_another_account_vault(): void
    {
        $this->createUser(['read']);

        $vault = Vault::factory()->create();
        $contact = Contact::factory()->create([
            'vault_id' => $vault->id,
        ]);

        $response = $this->get('/api/vaults/'.$vault->id.'/contacts/'.$contact->id);

        $response->assertResourceNotFound();
    }
}
